require "base64"

class Message < ApplicationRecord
  belongs_to :conversation, touch: true
  has_many_attached :images

  validate :images_belong_to_user_messages

  def api_json
    {
      id: id,
      role: role,
      content: content,
      thinking: thinking,
      total_tokens: total_tokens,
      tokens_per_second: tokens_per_second,
      generation_ms: generation_ms,
      images: serialized_images
    }
  end

  def content_for_ai
    return content unless images.attached?

    parts = []
    parts << { type: "text", text: content } if content.present?
    ordered_images.each do |attachment|
      encoded = Base64.strict_encode64(attachment.download)
      parts << {
        type: "image_url",
        image_url: { url: "data:#{attachment.blob.content_type};base64,#{encoded}" }
      }
    end
    parts
  end

  def ordered_images
    images_attachments.includes(:blob).order(:created_at, :id)
  end

  private

  def serialized_images
    ordered_images.map do |attachment|
      metadata = attachment.blob.metadata.symbolize_keys
      {
        id: attachment.id,
        filename: attachment.filename.to_s,
        content_type: attachment.blob.content_type,
        byte_size: attachment.blob.byte_size,
        width: metadata[:width],
        height: metadata[:height],
        download_url: "/api/conversations/#{conversation_id}/messages/#{id}/images/#{attachment.id}"
      }
    end
  end

  def images_belong_to_user_messages
    errors.add(:images, "can only be attached to user messages") if role != "user" && images.attached?
  end
end
