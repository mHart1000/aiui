class Message < ApplicationRecord
  belongs_to :conversation, touch: true
  has_many_attached :images

  validate :images_belong_to_user_messages

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

  def images_belong_to_user_messages
    errors.add(:images, "can only be attached to user messages") if role != "user" && images.attached?
  end
end
