# Streams a single chat turn for a user message that already exists in the
# conversation, yielding every SSE event (live and trailing) to a sink.
# The controller owns the stream itself and only forwards sink events.
class ChatStreamingService
  class EmptyStreamedResponseError < StandardError; end
  SEARCH_TRIGGER = /(?<!\w)@search\b/i

  def self.call(**kwargs)
    new(**kwargs).call
  end

  def self.message_signature(message)
    [ message.content, message.images.attachments.order(:id).pluck(:blob_id), message.pdf_sources ]
  end

  def initialize(user:, conversation:, answering_message:, model:, images_allowed:, time_zone: nil, sink:)
    @user = user
    @conversation = conversation
    @answering_message = answering_message
    @model = model
    @images_allowed = images_allowed
    @time_zone = time_zone
    @sink = sink
  end

  # => { status: :done | :disconnected | :stale | :failed, persisted: bool,
  #      error: exception (only :failed) }
  def call
    answering_id = @answering_message.id
    answering_signature = self.class.message_signature(@answering_message)

    thinking_accumulator = ""
    reply_accumulator = ""
    research_metadata = nil
    @persisted = false

    begin
      @user.reload
      rag_context = fetch_rag_context
      web_search_mode = if @answering_message.content.to_s.match?(SEARCH_TRIGGER)
        "always"
      else
        @conversation.resolved_web_search_mode
      end
      result = ChatService.call(
        messages: @conversation.messages_for_ai(multimodal: @images_allowed),
        model: @model,
        reasoning_effort: @user.reasoning_effort,
        use_persona: @user.use_persona,
        persona_id: @user.persona_id,
        use_scaffolding: @user.use_scaffolding,
        stream: true,
        rag_context: rag_context,
        project_description: @conversation.project&.description,
        skills: fetch_skills,
        web_search_mode: web_search_mode,
        web_search_level: @conversation.resolved_web_search_level,
        web_search_timing: @conversation.resolved_web_search_timing,
        web_search_query_count: @conversation.resolved_web_search_query_count,
        web_search_time_range: @conversation.web_search_time_range,
        web_search_start_date: @conversation.web_search_start_date,
        web_search_end_date: @conversation.web_search_end_date,
        time_zone: @time_zone,
        has_pdf_sources: @conversation.messages.where("pdf_sources <> '[]'::jsonb").exists?
      ) do |chunk, phase|
        if phase == :thinking
          thinking_accumulator += chunk
        elsif phase == :response
          reply_accumulator += chunk
        end

        event_data = if phase == :web_search
          research_metadata = chunk if chunk[:status].present?
          { type: "web_search", **chunk }
        elsif phase == :phase_change
          { type: "phase_change", phase: "responding" }
        else
          { type: phase.to_s, content: chunk }
        end
        @sink.call(event_data)
      end

      raise "Chat service failed: #{result[:error]}" if result&.dig(:error)
      if reply_accumulator.blank? && thinking_accumulator.blank?
        raise EmptyStreamedResponseError,
          "Model stream completed without response content " \
          "(finish_reason=#{result&.dig(:finish_reason).inspect}, " \
          "completion_tokens=#{result&.dig(:tokens, :completion_tokens).inspect})"
      end

      @persisted = persist_streamed_response(
        @conversation,
        answering_id,
        answering_signature,
        reply: reply_accumulator,
        thinking: thinking_accumulator,
        tokens: result&.dig(:tokens),
        stats: result&.dig(:stats),
        model_label: result&.dig(:model_label),
        persona_label: result&.dig(:persona_label),
        persona_version: result&.dig(:persona_version),
        skill_versions: result&.dig(:skill_versions),
        web_search_data: result&.dig(:web_search_data) || research_metadata || {},
        entitle: true
      )
      return { status: :stale, persisted: false } unless @persisted

      if result&.dig(:stats)
        stats_event = {
          type: "stats",
          generation_ms: result[:stats][:elapsed_ms],
          tokens_per_second: result[:stats][:tokens_per_second],
          total_tokens: result.dig(:tokens, :total_tokens) || result.dig(:tokens, :total)
        }
        @sink.call(stats_event)
      end

      metadata_event = {
        type: "metadata",
        model_label: result&.dig(:model_label),
        persona_label: result&.dig(:persona_label)
      }
      @sink.call(metadata_event)

      @sink.call({ type: "done" })
      { status: :done, persisted: true }
    rescue ActionController::Live::ClientDisconnected
      unless @persisted
        @persisted = persist_streamed_response(
          @conversation,
          answering_id,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          entitle: false,
          web_search_data: research_metadata || {}
        )
      end
      { status: :disconnected, persisted: @persisted }
    rescue StandardError => e
      Rails.logger.error("Streaming chat failed for conversation #{@conversation.id}: #{e.full_message}")
      message = if e.is_a?(EmptyStreamedResponseError)
        "The model returned no response content. Please retry."
      else
        "The response could not be generated. Please retry."
      end
      @sink.call({ type: "error", error: message })
      { status: :failed, persisted: @persisted, error: e }
    end
  end

  # Public because the controller test exercises the edit-vs-persist race
  # directly against it.
  def persist_streamed_response(conversation, answering_id, answering_signature, reply:, thinking:, tokens: nil, stats: nil, model_label: nil, persona_label: nil, persona_version: nil, skill_versions: nil, web_search_data: {}, entitle:)
    return false if reply.blank? && thinking.blank?

    conversation.with_lock do
      answering_message = conversation.messages.find_by(id: answering_id)
      next false unless answering_message && self.class.message_signature(answering_message) == answering_signature

      conversation.add_assistant_message(
        reply: reply,
        thinking: thinking,
        tokens: tokens,
        stats: stats,
        model_label: model_label,
        persona_label: persona_label,
        persona_version: persona_version,
        skill_versions: skill_versions,
        web_search_data: web_search_data
      )
      conversation.entitle_async(answering_message.content) if entitle && answering_message.content.present?
      true
    end
  end

  private

  def fetch_skills
    @conversation.resolved_skills.map do |skill|
      { id: skill.id, name: skill.name, content: skill.body, version: skill.version }
    end
  end

  def fetch_rag_context
    unless @conversation.rag_enabled
      Rails.logger.info("[RAG] skipped: rag_enabled is false on conversation #{@conversation.id}")
      return nil
    end
    query = @answering_message.content
    return nil if query.blank?

    Rails.logger.info("[RAG] query: #{query.to_s[0, 200]}")
    chunks = Rag::Retriever.call(user: @user, query: query)
    Rails.logger.info("[RAG] retrieved #{chunks.length} chunks")
    chunks.each_with_index do |chunk, index|
      label = chunk.rag_document&.original_filename || chunk.rag_document&.title || "doc##{chunk.rag_document_id}"
      preview = chunk.content.to_s.gsub(/\s+/, " ")[0, 140]
      Rails.logger.info("[RAG]   #{index + 1}. #{label} chunk##{chunk.chunk_index}: #{preview}")
    end
    return nil if chunks.blank?

    context = Rag::ContextFormatter.format(chunks, budgets: WebResearch::Profile.for_level(@conversation.resolved_web_search_level))
    Rails.logger.info("[RAG] injected context: #{context.to_s.length} chars")
    context
  end
end
