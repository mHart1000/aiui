module Api
  class MessageImagesController < ApplicationController
    before_action :authenticate_api_user!

    def show
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = conversation.messages.find(params[:id])
      attachment = message.images_attachments.find(params[:attachment_id])

      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data attachment.download,
        type: attachment.blob.content_type,
        filename: attachment.filename.sanitized,
        disposition: "inline"
    end
  end
end
