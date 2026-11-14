module Api
  class MessagesController < ApplicationController
    MAX_ATTACHMENTS = 64

    before_action :authenticate_api_user!
    include ActionController::Live

    def update
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = nil
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
      validate_attachment_count!
      processed_attachments = []
      begin
        processed_attachments = process_attachment_uploads!
        processed_images = processed_attachments.filter_map(&:image)
        processed_pdfs = processed_attachments.filter_map(&:pdf_source)
        answering_message = prepare_answering_message!(
          conversation, regenerating, processed_images, processed_pdfs, model_code: safe_model_code
        )
      ensure
        processed_attachments.filter_map(&:image).each(&:close!)
      end

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      sink = ->(event) { response.stream.write("data: #{event.to_json}\n\n") }
      begin
        outcome = ChatStreamingService.call(
          user: current_api_user,
          conversation: conversation,
          answering_message: answering_message,
          model: safe_model_code,
          images_allowed: images_allowed,
          time_zone: params[:time_zone],
          sink: sink
        )
        raise outcome[:error] if outcome[:status] == :failed
      ensure
        response.stream.close
      end
    end

    private

    def prepare_answering_message!(conversation, regenerating, processed_images, processed_pdfs, model_code:)
      unless regenerating
        return create_user_message!(conversation, params[:content].to_s, processed_images, processed_pdfs, model_code: model_code)
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

    def create_user_message!(conversation, content, processed_images, processed_pdfs, model_code:)
      conversation.transaction do
        conversation.apply_model_code(model_code)
        message = conversation.messages.build(role: "user", content: content, pdf_sources: processed_pdfs.map(&:source))
        message.images.attach(processed_images.map(&:attachable))
        message.save!
        message
      end
    end

    def process_attachment_uploads!
      text_limit = PdfAttachmentProcessor.text_limit(params[:pdf_text_limit].presence || PdfAttachmentProcessor::DEFAULT_TEXT_CHARS)
      attachment_uploads.each_with_object([]) do |upload, processed|
        remaining = text_limit - processed.filter_map(&:pdf_source).sum { |result| result.text.length }
        processed << MessageAttachmentProcessor.call(upload: upload, max_pdf_text_chars: remaining)
      end
    end

    def validate_attachment_count!
      return if attachment_uploads.size <= MAX_ATTACHMENTS

      raise ImageAttachmentProcessor::Error, "You can attach up to #{MAX_ATTACHMENTS} files."
    end

    def attachment_uploads
      Array(params[:attachments]).reject(&:blank?)
    end
  end
end
