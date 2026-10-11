class Message < ApplicationRecord
  PDF_SOURCE_OPEN = "[External PDF sources]".freeze
  PDF_SOURCE_CLOSE = "[/External PDF sources]".freeze

  belongs_to :conversation, touch: true
  has_many_attached :images

  validate :images_belong_to_user_messages

  # Chat-completions payload: a plain string, or an OpenAI content array when the
  # model can see images. See docs/image-attachments-spec.md §2.4.
  def to_ai_payload(multimodal: false)
    attached = images.attachments
    text = content_with_pdf_sources
    return { role: role, content: text } if attached.empty?
    return { role: role, content: content_with_image_markers(text, attached) } unless multimodal

    parts = []
    parts << { type: "text", text: text } if text.present?
    parts.concat(attached.map { |a| { type: "image_url", image_url: { url: data_url(a.blob) } } })
    { role: role, content: parts }
  end

  private

  def data_url(blob)
    "data:#{blob.content_type};base64,#{Base64.strict_encode64(blob.download)}"
  end

  # Text-only models still need to know an image was there, or the reply reads as a non-sequitur.
  def content_with_pdf_sources
    return content if pdf_sources.blank?

    source_json = JSON.generate(sources: pdf_sources.map { |source|
      { filename: source.fetch("filename"), text: source.fetch("text") }
    })
    [ content.presence, PDF_SOURCE_OPEN, source_json, PDF_SOURCE_CLOSE ].compact.join("\n\n")
  end

  def content_with_image_markers(text, attached)
    markers = attached.map { |a| "[Image attached: #{a.filename}]" }
    [ text.presence, *markers ].compact.join("\n\n")
  end

  def images_belong_to_user_messages
    errors.add(:images, "can only be attached to user messages") if role != "user" && images.attached?
  end
end
