module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    class RequestError < StandardError
      attr_reader :code, :status

      def initialize(code, message, status: 422)
        @code = code
        @status = status
        super(message)
      end
    end

    def create
      conversation = current_api_user.conversations.find(params[:conversation_id])
      uploads = uploaded_images
      validate_message_input!(uploads, regenerating: false)
      safe_model_code = resolved_model_code(conversation)
      enforce_image_capability!(conversation, safe_model_code, uploads)
      user_message = create_user_message!(conversation, params[:content].to_s, uploads, model_code: safe_model_code)

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, user_message.content)
      result = ChatService.call(
        messages: conversation.messages_for_ai,
        model: safe_model_code,
        use_persona: current_api_user.use_persona,
        persona_id: current_api_user.persona_id,
        use_scaffolding: current_api_user.use_scaffolding,
        rag_context: rag_context,
        skills: fetch_skills(conversation)
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        conversation.add_assistant_message(
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          stats: result[:stats],
          persona_version: result[:persona_version],
          skill_versions: result[:skill_versions]
        )
        conversation.entitle_async(title_seed(user_message))

        render json: {
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          generation_ms: result[:stats]&.dig(:elapsed_ms),
          tokens_per_second: result[:stats]&.dig(:tokens_per_second)
        }
      end
    rescue RequestError, ImageAttachmentProcessor::Error => e
      render_request_error(e)
    end

    def update
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = conversation.messages.find(params[:id])
      content = params[:content].to_s
      if content.blank? && !message.images.attached?
        raise RequestError.new("message_content_required", "A message must contain text or at least one image.")
      end

      conversation.truncate_after_message(message)
      message.update!(content: content)
      render json: { message: message.api_json }
    rescue RequestError => e
      render_request_error(e)
    end

    def create_streaming
      conversation = current_api_user.conversations.find(params[:conversation_id])
      regenerating = ActiveModel::Type::Boolean.new.cast(params[:regenerating])
      uploads = uploaded_images
      validate_message_input!(uploads, regenerating: regenerating)
      safe_model_code = resolved_model_code(conversation)
      enforce_image_capability!(conversation, safe_model_code, uploads)
      answering_message = prepare_answering_message!(conversation, uploads, regenerating, safe_model_code)

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      answering_signature = prompt_signature(answering_message)
      thinking_accumulator = ""
      reply_accumulator = ""
      client_disconnected = false
      generation_failed = false
      response_persisted = false
      stream_result = nil

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, answering_message.content)

      begin
        stream_result = ChatService.call(
          messages: conversation.messages_for_ai,
          model: safe_model_code,
          use_persona: current_api_user.use_persona,
          persona_id: current_api_user.persona_id,
          use_scaffolding: current_api_user.use_scaffolding,
          stream: true,
          rag_context: rag_context,
          skills: fetch_skills(conversation)
        ) do |chunk, phase|
          if phase == :thinking
            thinking_accumulator += chunk
          elsif phase == :response
            reply_accumulator += chunk
          end

          event_data = if phase == :phase_change
            { type: "phase_change", phase: "responding" }
          else
            { type: phase.to_s, content: chunk }
          end
          response.stream.write("data: #{event_data.to_json}\n\n")
        end

        response_persisted = persist_streamed_response(
          conversation,
          answering_message,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          result: stream_result,
          entitle: true
        )

        if stream_result&.dig(:stats)
          stats_event = {
            type: "stats",
            generation_ms: stream_result[:stats][:elapsed_ms],
            tokens_per_second: stream_result[:stats][:tokens_per_second],
            total_tokens: stream_result.dig(:tokens, :total_tokens) || stream_result.dig(:tokens, :total)
          }
          response.stream.write("data: #{stats_event.to_json}\n\n")
        end

        response.stream.write("data: #{({ type: 'done' }).to_json}\n\n")
      rescue ActionController::Live::ClientDisconnected
        client_disconnected = true
        Rails.logger.warn("MessagesController: client disconnected during stream, saving accumulated content")
      rescue => e
        generation_failed = true
        Rails.logger.error("Streaming generation failed: #{e.full_message}")
        response.stream.write("data: #{({ type: 'error', content: 'Generation failed. You can retry this message.' }).to_json}\n\n")
      ensure
        response.stream.close
      end

      if client_disconnected && !generation_failed && !response_persisted
        persist_streamed_response(
          conversation,
          answering_message,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          result: stream_result,
          entitle: false
        )
      end
    rescue RequestError, ImageAttachmentProcessor::Error => e
      render_request_error(e)
    end

    private

    def prepare_answering_message!(conversation, uploads, regenerating, model_code)
      unless regenerating
        return create_user_message!(conversation, params[:content].to_s, uploads, model_code: model_code)
      end

      Conversation.transaction do
        conversation.apply_model_code(model_code)
        if params[:message_id].present?
          conversation.truncate_from_message(conversation.messages.find(params[:message_id]))
        else
          while (last_message = conversation.messages.order(:created_at, :id).last)&.role == "assistant"
            last_message.destroy
          end
        end

        message = conversation.messages.order(:created_at, :id).last
        unless message&.role == "user"
          raise RequestError.new("message_content_required", "There is no user message to regenerate.")
        end
        message
      end
    end

    def persist_streamed_response(conversation, answering_message, answering_signature, reply:, thinking:, result:, entitle:)
      current_message = conversation.messages.find_by(id: answering_message.id)
      superseded = current_message.nil? || prompt_signature(current_message) != answering_signature
      return false if superseded || (reply.blank? && thinking.blank?)

      conversation.add_assistant_message(
        reply: reply,
        thinking: thinking,
        tokens: result&.dig(:tokens),
        stats: result&.dig(:stats),
        persona_version: result&.dig(:persona_version),
        skill_versions: result&.dig(:skill_versions)
      )
      conversation.entitle_async(title_seed(answering_message)) if entitle
      true
    end

    def prompt_signature(message)
      [
        message.content,
        message.images_attachments.order(:id).pluck(:blob_id)
      ]
    end

    def create_user_message!(conversation, content, uploads, model_code:)
      processed = ImageAttachmentProcessor.call(uploads)
      created_blobs = []

      message = Conversation.transaction do
        conversation.apply_model_code(model_code)
        new_message = conversation.messages.create!(role: "user", content: content)
        if processed.any?
          processed.each { |image| image.tempfile.rewind }
          new_message.images.attach(processed.map(&:attachable))
          created_blobs = new_message.images.blobs.to_a
        end
        new_message
      end
      message
    rescue
      created_blobs.each(&:purge)
      raise
    ensure
      processed&.each(&:close!)
    end

    def validate_message_input!(uploads, regenerating:)
      if regenerating
        if uploads.any?
          raise RequestError.new("images_not_allowed_on_regeneration", "Regeneration reuses the images already stored with the message.")
        end
        return
      end

      if params[:content].to_s.blank? && uploads.empty?
        raise RequestError.new("message_content_required", "A message must contain text or at least one image.")
      end
      if uploads.length > ImageAttachmentProcessor::MAX_IMAGES
        raise RequestError.new("too_many_images", "A message may contain at most four images.")
      end
    end

    def uploaded_images
      value = params[:images]
      return [] if value.blank?
      return value.values if value.is_a?(ActionController::Parameters)
      Array(value)
    end

    def resolved_model_code(conversation)
      requested = params[:model_code]
      valid = requested if AI_MODELS.any? { |model| model["id"] == requested }
      valid || conversation.model_code || ChatService::FALLBACK_MODEL
    end

    def enforce_image_capability!(conversation, model_code, uploads)
      return unless uploads.any? || conversation.has_images?

      capability = ImageCapabilityService.call(model_code: model_code)
      case capability[:image_input]
      when "supported"
        nil
      when "unsupported"
        raise RequestError.new("image_input_unsupported", "The selected model does not accept images.")
      else
        raise RequestError.new(
          "image_capability_unknown",
          "Image support could not be verified for the selected model. Retry the capability check.",
          status: 503
        )
      end
    end

    def render_request_error(error)
      render json: { error: { code: error.code, message: error.message } }, status: error.status
    end

    def title_seed(message)
      return message.content if message.content.present?

      original = message.ordered_images.first&.blob&.metadata&.dig("original_filename")
      File.basename(original.to_s, File.extname(original.to_s)).presence || "Image Chat"
    end

    def fetch_skills(conversation)
      conversation.resolved_skills.map do |skill|
        { id: skill.id, name: skill.name, content: skill.body, version: skill.version }
      end
    end

    def fetch_rag_context(conversation, query)
      unless conversation.rag_enabled
        Rails.logger.info("[RAG] skipped: rag_enabled is false on conversation #{conversation.id}")
        return nil
      end
      return nil if query.blank?

      Rails.logger.info("[RAG] query: #{query.to_s[0, 200]}")
      chunks = Rag::Retriever.call(user: current_api_user, query: query)
      Rails.logger.info("[RAG] retrieved #{chunks.length} chunks")
      chunks.each_with_index do |chunk, index|
        label = chunk.rag_document&.original_filename || chunk.rag_document&.title || "doc##{chunk.rag_document_id}"
        preview = chunk.content.to_s.gsub(/\s+/, " ")[0, 140]
        Rails.logger.info("[RAG]   #{index + 1}. #{label} chunk##{chunk.chunk_index}: #{preview}")
      end
      return nil if chunks.blank?

      context = Rag::ContextFormatter.format(chunks)
      Rails.logger.info("[RAG] injected context: #{context.to_s.length} chars")
      context
    rescue => e
      Rails.logger.warn("RAG retrieval failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
