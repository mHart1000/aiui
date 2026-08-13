class Message < ApplicationRecord
  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  MAX_IMAGES = 4
  MAX_IMAGE_BYTES = 8.megabytes

  belongs_to :conversation, touch: true
  has_many_attached :images

  validate :images_within_limits

  # Chat-completions payload: a plain string, or an OpenAI content array when the
  # model can see images. See docs/image-attachments-spec.md §2.4.
  def to_ai_payload(multimodal: false)
    attached = images.attachments
    return { role: role, content: content } if attached.empty?
    return { role: role, content: content_with_image_markers(attached) } unless multimodal

    parts = []
    parts << { type: "text", text: content } if content.present?
    parts.concat(attached.map { |a| { type: "image_url", image_url: { url: data_url(a.blob) } } })
    { role: role, content: parts }
  end

  private

  def data_url(blob)
    "data:#{blob.content_type};base64,#{Base64.strict_encode64(blob.download)}"
  end

  # Text-only models still need to know an image was there, or the reply reads as a non-sequitur.
  def content_with_image_markers(attached)
    markers = attached.map { |a| "[Image attached: #{a.filename}]" }
    [ content.presence, *markers ].compact.join("\n\n")
  end

  def images_within_limits
    attached = images.attachments
    return if attached.empty?

    errors.add(:images, "cannot exceed #{MAX_IMAGES} per message") if attached.size > MAX_IMAGES

    attached.each do |attachment|
      blob = attachment.blob
      next if blob.nil?

      unless IMAGE_CONTENT_TYPES.include?(blob.content_type)
        errors.add(:images, "must be PNG, JPEG, WebP or GIF")
      end
      if blob.byte_size > MAX_IMAGE_BYTES
        errors.add(:images, "must be under #{MAX_IMAGE_BYTES / 1.megabyte} MB")
      end
    end
  end
end
