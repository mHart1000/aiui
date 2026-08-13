module Api
  class AttachmentsController < ApplicationController
    before_action :authenticate_api_user!

    DEFAULT_MAX_PIXELS = 6_000_000

    def create
      file = params[:file]
      unless file.respond_to?(:original_filename) && file.respond_to?(:tempfile)
        return render json: { error: "missing file" }, status: :unprocessable_entity
      end
      unless Message::IMAGE_CONTENT_TYPES.include?(file.content_type)
        return render json: { error: "unsupported image format: #{file.content_type}" }, status: :unprocessable_entity
      end
      if file.size > Message::MAX_IMAGE_BYTES
        return render json: { error: "image must be under #{Message::MAX_IMAGE_BYTES / 1.megabyte} MB" },
                      status: :unprocessable_entity
      end

      io, width, height = prepare_image(file)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: io,
        filename: file.original_filename,
        content_type: file.content_type
      )

      render json: {
        signed_id: blob.signed_id,
        url: rails_blob_path(blob, only_path: true),
        filename: blob.filename.to_s,
        width: width,
        height: height
      }, status: :created
    rescue Vips::Error => e
      Rails.logger.warn("Attachment: unreadable image — #{e.message}")
      render json: { error: "could not read image" }, status: :unprocessable_entity
    end

    private

    # Images at or below the cap are stored byte-for-byte; only oversized or
    # EXIF-rotated ones go through vips. See docs/image-attachments-spec.md §2.2.
    def prepare_image(file)
      path = file.tempfile.path
      image = Vips::Image.new_from_file(path)
      cap = current_api_user.image_max_pixels || DEFAULT_MAX_PIXELS

      oversized = image.width * image.height > cap
      # llama.cpp's loader ignores EXIF, so a rotated image must be baked upright.
      rotated = exif_orientation(image) > 1
      return [ file.tempfile, image.width, image.height ] unless oversized || rotated

      processed = build_pipeline(path, image, cap, oversized).call
      output = Vips::Image.new_from_file(processed.path)
      [ processed, output.width, output.height ]
    end

    # ImageProcessing::Vips applies EXIF orientation on load, so autorot is implicit.
    def build_pipeline(path, image, cap, oversized)
      pipeline = ImageProcessing::Vips.source(path)
      return pipeline unless oversized

      # Scale to the cap, not below it — shrinking further loses detail for nothing.
      scale = Math.sqrt(cap.to_f / (image.width * image.height))
      pipeline.resize_to_limit((image.width * scale).round, (image.height * scale).round)
    end

    def exif_orientation(image)
      return 1 if image.get_typeof("orientation").zero?
      image.get("orientation").to_i
    end
  end
end
