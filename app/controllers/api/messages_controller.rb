module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    def update
      conversation = current_api_user.conversations.find(params[:conversation_id])
      conversation.with_lock do
        message = conversation.messages.find(params[:id])
        conversation.messages.where("created_at > ?", message.created_at).destroy_all
        message.update!(content: params[:content].to_s)
      end
      render json: { message: message }
    end

    def create_streaming
      conversation = current_api_user.conversations.find(params[:conversation_id])
      regenerating = ActiveModel::Type::Boolean.new.cast(params[:regenerating])
      safe_model_code = conversation.resolve_model_code(params[:model_code])
      images_allowed = AiModels.images_allowed?(safe_model_code)
      processed_images = process_image_uploads!(image_uploads)
      begin
        answering_message = prepare_answering_message!(
          conversation, regenerating, processed_images, model_code: safe_model_code
        )
      ensure
        processed_images.each(&:close!)
      end

      answering_id = answering_message.id
      answering_signature = message_signature(answering_message)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      thinking_accumulator = ""
      reply_accumulator = ""
      response_persisted = false

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, answering_message.content)

      begin
        result = ChatService.call(
          messages: conversation.messages_for_ai(multimodal: images_allowed),
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

        raise "Chat service failed: #{result[:error]}" if result&.dig(:error)

        response_persisted = persist_streamed_response(
          conversation,
          answering_id,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          tokens: result&.dig(:tokens),
          stats: result&.dig(:stats),
          persona_version: result&.dig(:persona_version),
          skill_versions: result&.dig(:skill_versions),
          entitle: true
        )
        return unless response_persisted

        if result&.dig(:stats)
          stats_event = {
            type: "stats",
            generation_ms: result[:stats][:elapsed_ms],
            tokens_per_second: result[:stats][:tokens_per_second],
            total_tokens: result.dig(:tokens, :total_tokens) || result.dig(:tokens, :total)
          }
          response.stream.write("data: #{stats_event.to_json}\n\n")
        end

        response.stream.write("data: #{({ type: 'done' }).to_json}\n\n")
      rescue ActionController::Live::ClientDisconnected
        persist_streamed_response(
          conversation,
          answering_id,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          entitle: false
        ) unless response_persisted
      ensure
        response.stream.close
      end
    end

    private

    def prepare_answering_message!(conversation, regenerating, processed_images, model_code:)
      unless regenerating
        return create_user_message!(conversation, params[:content].to_s, processed_images, model_code: model_code)
      end

      conversation.with_lock do
        conversation.apply_model_code(model_code)

        if params[:message_id].present?
          conversation.truncate_from_message(conversation.messages.find(params[:message_id]))
        else
          while (last_message = conversation.messages.order(:created_at, :id).last)&.role == "assistant"
            last_message.destroy
          end
        end

        message = conversation.messages.order(:created_at, :id).last
        raise ActiveRecord::RecordNotFound, "There is no user message to regenerate" unless message&.role == "user"
        message
      end
    end

    def create_user_message!(conversation, content, processed_images, model_code:)
      conversation.transaction do
        conversation.apply_model_code(model_code)
        message = conversation.messages.build(role: "user", content: content)
        message.images.attach(processed_images.map(&:attachable))
        message.save!
        message
      end
    end

    def process_image_uploads!(uploads)
      processed = []
      uploads.each { |upload| processed << ImageAttachmentProcessor.call(upload: upload) }
      processed
    rescue
      processed&.each(&:close!)
      raise
    end

    def image_uploads
      uploads = Array(params[:images]).reject(&:blank?)
      if uploads.size > 4
        raise ImageAttachmentProcessor::Error, "You can attach up to 4 images."
      end
      uploads
    end

    def persist_streamed_response(conversation, answering_id, answering_signature, reply:, thinking:, tokens: nil, stats: nil, persona_version: nil, skill_versions: nil, entitle:)
      return false if reply.blank? && thinking.blank?

      conversation.with_lock do
        answering_message = conversation.messages.find_by(id: answering_id)
        next false unless answering_message && message_signature(answering_message) == answering_signature

        conversation.add_assistant_message(
          reply: reply,
          thinking: thinking,
          tokens: tokens,
          stats: stats,
          persona_version: persona_version,
          skill_versions: skill_versions
        )
        conversation.entitle_async(answering_message.content) if entitle && answering_message.content.present?
        true
      end
    end

    def message_signature(message)
      [ message.content, message.images.attachments.order(:id).pluck(:blob_id) ]
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
