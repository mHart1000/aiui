module Api
  class MessageImagesController < ApplicationController
    before_action :authenticate_api_user!

    def show
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = conversation.messages.find(params[:message_id])
      attachment = message.images_attachments.find(params[:attachment_id])

      response.headers["Cache-Control"] = "private, max-age=3600"
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data attachment.download,
        type: attachment.blob.content_type,
        filename: attachment.filename.sanitized,
        disposition: "inline"
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: { code: "image_not_found", message: "The saved image was not found." }
      }, status: :not_found
    end
  end
end
