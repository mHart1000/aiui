module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    class RequestError < StandardError
      attr_reader :code, :status

      def initialize(code, message, status: :unprocessable_content)
        @code = code
        @status = status
        super(message)
      end
    end

    def create
      conversation = current_api_user.conversations.find(params[:conversation_id])
      uploads = image_uploads
      validate_message_input!(uploads)
      safe_model_code = conversation.resolve_model_code(params[:model_code])
      images_allowed = AiModels.images_allowed?(safe_model_code)
      enforce_image_capability!(images_allowed, uploads)
      processed_images = process_image_uploads!(uploads)
      begin
        user_message = create_user_message!(
          conversation, params[:content].to_s, processed_images, model_code: safe_model_code
        )
      ensure
        processed_images.each(&:close!)
      end

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, user_message.content)
      result = ChatService.call(
        messages: conversation.messages_for_ai(multimodal: images_allowed),
        model: safe_model_code,
        use_persona: current_api_user.use_persona,
        persona_id: current_api_user.persona_id,
        use_scaffolding: current_api_user.use_scaffolding,
        rag_context: rag_context,
        skills: fetch_skills(conversation)
      )

      if result[:error]
        Rails.logger.error("MessagesController#create generation failed: #{result[:error]}")
        render_api_error("generation_failed", "Generation failed. You can retry this message.", :bad_gateway)
      else
        conversation.add_assistant_message(
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          stats: result[:stats],
          persona_version: result[:persona_version],
          skill_versions: result[:skill_versions]
        )
        conversation.entitle_async(user_message.content) if user_message.content.present?

        render json: {
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          generation_ms: result[:stats]&.dig(:elapsed_ms),
          tokens_per_second: result[:stats]&.dig(:tokens_per_second)
        }
      end
    rescue RequestError => e
      render_request_error(e)
    rescue ActiveRecord::RecordNotFound
      render_api_error("resource_not_found", "The conversation or message was not found.", :not_found)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("MessagesController#create persistence failed: #{e.full_message}")
      render_api_error("invalid_message", e.record.errors.full_messages.to_sentence, :unprocessable_content)
    rescue => e
      Rails.logger.error("MessagesController#create: #{e.full_message}")
      render_api_error("generation_failed", "Generation failed. You can retry this message.", :bad_gateway)
    end

    def update
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = conversation.messages.find(params[:id])
      content = params[:content].to_s
      if content.blank? && !message.images.attached?
        raise RequestError.new("message_content_required", "A message must contain text or at least one image.")
      end

      conversation.messages.where("created_at > ?", message.created_at).destroy_all
      message.update!(content: content)
      render json: { message: message }
    rescue RequestError => e
      render_request_error(e)
    rescue ActiveRecord::RecordNotFound
      render_api_error("resource_not_found", "The conversation or message was not found.", :not_found)
    rescue ActiveRecord::RecordInvalid => e
      render_api_error("invalid_message", e.record.errors.full_messages.to_sentence, :unprocessable_content)
    end

    def create_streaming
      conversation = current_api_user.conversations.find(params[:conversation_id])
      regenerating = ActiveModel::Type::Boolean.new.cast(params[:regenerating])
      uploads = image_uploads

      if regenerating && uploads.any?
        raise RequestError.new("images_not_allowed_on_regeneration", "Regeneration reuses images already stored with the message.")
      end
      validate_message_input!(uploads) unless regenerating
      safe_model_code = conversation.resolve_model_code(params[:model_code])
      images_allowed = AiModels.images_allowed?(safe_model_code)
      enforce_image_capability!(images_allowed, uploads)
      processed_images = process_image_uploads!(uploads)
      begin
        answering_message = prepare_answering_message!(
          conversation, regenerating, processed_images, model_code: safe_model_code
        )
      ensure
        processed_images.each(&:close!)
      end

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

        raise "Chat service failed: #{stream_result[:error]}" if stream_result&.dig(:error)

        response_persisted = persist_streamed_response(
          conversation,
          answering_message,
          answering_signature,
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          result: stream_result,
          entitle: true
        )
        raise "The answered user turn changed before the response could be saved" unless response_persisted

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
        Rails.logger.warn("MessagesController: client disconnected during stream")
      rescue => e
        generation_failed = true
        Rails.logger.error("MessagesController#create_streaming: #{e.full_message}")
        write_stream_error("Generation failed. You can retry this message.")
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
    rescue RequestError => e
      render_request_error(e)
    rescue ActiveRecord::RecordNotFound
      render_api_error("resource_not_found", "The conversation or message was not found.", :not_found)
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("MessagesController#create_streaming persistence failed: #{e.full_message}")
      render_api_error("invalid_message", e.record.errors.full_messages.to_sentence, :unprocessable_content)
    rescue => e
      Rails.logger.error("MessagesController#create_streaming setup failed: #{e.full_message}")
      render_api_error("stream_setup_failed", "The response stream could not be started.", :internal_server_error)
    end

    private

    def prepare_answering_message!(conversation, regenerating, processed_images, model_code:)
      unless regenerating
        return create_user_message!(conversation, params[:content].to_s, processed_images, model_code: model_code)
      end

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

    def create_user_message!(conversation, content, processed_images, model_code:)
      message = nil
      blobs = []
      conversation.transaction do
        conversation.apply_model_code(model_code)
        message = conversation.messages.build(role: "user", content: content)
        message.images.attach(processed_images.map(&:attachable))
        blobs = message.images.blobs.to_a
        message.save!
      end
      message
    rescue ActiveRecord::RecordInvalid
      cleanup_failed_message_uploads(message, blobs)
      raise
    rescue => e
      cleanup_failed_message_uploads(message, blobs)
      Rails.logger.error("MessagesController image persistence failed: #{e.full_message}")
      raise RequestError.new("upload_failed", "The images could not be stored.", status: :internal_server_error)
    end

    def process_image_uploads!(uploads)
      processed = []
      uploads.each { |upload| processed << ImageAttachmentProcessor.call(upload: upload) }
      processed
    rescue ImageAttachmentProcessor::Error => e
      processed&.each(&:close!)
      raise RequestError.new(e.code, e.message, status: e.status)
    rescue
      processed&.each(&:close!)
      raise
    end

    def cleanup_failed_message_uploads(message, blobs)
      message.destroy! if message&.id && Message.exists?(message.id)
      blobs.each do |blob|
        next unless blob.id && ActiveStorage::Blob.exists?(blob.id)

        ActiveStorage::Blob.find(blob.id).purge
      end
    rescue => cleanup_error
      Rails.logger.error("MessagesController upload cleanup failed: #{cleanup_error.full_message}")
    end

    def image_uploads
      Array(params[:images]).reject(&:blank?)
    end

    def validate_message_input!(uploads)
      if params[:content].to_s.blank? && uploads.empty?
        raise RequestError.new("message_content_required", "A message must contain text or at least one image.")
      end
      if uploads.length > ImageAttachmentProcessor::MAX_IMAGES
        raise RequestError.new("too_many_images", "A message may contain at most four images.")
      end
    end

    def enforce_image_capability!(images_allowed, uploads)
      return if uploads.empty? || images_allowed

      raise RequestError.new("image_input_unsupported", "The selected model does not accept images.")
    end

    def persist_streamed_response(conversation, answering_message, answering_signature, reply:, thinking:, result:, entitle:)
      current_message = conversation.messages.find_by(id: answering_message.id)
      return false if current_message.nil? || prompt_signature(current_message) != answering_signature
      return false if reply.blank? && thinking.blank?

      conversation.add_assistant_message(
        reply: reply,
        thinking: thinking,
        tokens: result&.dig(:tokens),
        stats: result&.dig(:stats),
        persona_version: result&.dig(:persona_version),
        skill_versions: result&.dig(:skill_versions)
      )
      conversation.entitle_async(answering_message.content) if entitle && answering_message.content.present?
      true
    end

    def prompt_signature(message)
      [ message.content, message.images_attachments.order(:id).pluck(:blob_id) ]
    end

    def write_stream_error(message)
      payload = { type: "error", error: { code: "generation_failed", message: message } }
      response.stream.write("data: #{payload.to_json}\n\n")
    rescue ActionController::Live::ClientDisconnected, IOError
      nil
    end

    def render_request_error(error)
      render_api_error(error.code, error.message, error.status)
    end

    def render_api_error(code, message, status)
      render json: { error: { code: code, message: message } }, status: status
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
