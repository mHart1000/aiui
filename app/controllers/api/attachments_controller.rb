module Api
  class AttachmentsController < ApplicationController
    before_action :authenticate_api_user!

    def create
      processed = ImageAttachmentProcessor.call(
        upload: params[:file],
        max_pixels: current_api_user.image_max_pixels || User::DEFAULT_IMAGE_MAX_PIXELS
      )
      expires_at = PendingImageUpload::TTL.from_now

      blob = ActiveStorage::Blob.create_and_upload!(
        io: processed.tempfile,
        filename: processed.filename,
        content_type: processed.content_type,
        metadata: {
          width: processed.width,
          height: processed.height,
          original_filename: processed.original_filename
        },
        identify: false
      )
      pending = current_api_user.pending_image_uploads.create!(blob: blob, expires_at: expires_at)

      render json: {
        id: pending.id,
        signed_id: pending.client_signed_id,
        expires_at: pending.expires_at.iso8601,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        width: processed.width,
        height: processed.height
      }, status: :created
    rescue ImageAttachmentProcessor::Error => e
      render_error(e.code, e.message, e.status)
    rescue => e
      blob&.purge if blob && pending.nil?
      Rails.logger.error("AttachmentsController#create: #{e.full_message}")
      render_error("upload_failed", "The image could not be stored.", :internal_server_error)
    ensure
      processed&.close!
    end

    def destroy
      pending = current_api_user.pending_image_uploads.find(params[:id])
      if pending.blob.attachments.exists?
        return render_error("attachment_already_used", "The image is already attached to a message.", :conflict)
      end

      pending.destroy!
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render_error("attachment_not_found", "The pending image was not found.", :not_found)
    end

    private

    def render_error(code, message, status)
      render json: { error: { code: code, message: message } }, status: status
    end
  end
end
