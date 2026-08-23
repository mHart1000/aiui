class Message < ApplicationRecord
  belongs_to :conversation, touch: true

  # Builds the OpenAI-compatible content for a message. Plain string when there
  # are no images; the multimodal content-array form when image_data is present.
  def multimodal_content
    return content if image_data.blank?

    [ { type: "text", text: content }, *image_data.map { |uri| { type: "image_url", image_url: { url: uri } } } ]
  end
end
