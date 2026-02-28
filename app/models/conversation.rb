class Conversation < ApplicationRecord
  PLACEHOLDER_TITLE = "New Chat".freeze

  has_many :messages, dependent: :destroy
  belongs_to :user

  def entitle_async(content)
    ConversationEntitleJob.perform_later(id, content)
  end

  def placeholder_title?
    title == PLACEHOLDER_TITLE
  end

  def entitle(content)
    return if title.present? && !placeholder_title?

    begin
      result = ChatService.call(
        messages: [
          { role: "system", content: "Generate a short 3-6 word chat title in the style of an article title, based on the following user message. No punctuation." },
          { role: "user", content: content }
        ],
        model: model_code
      )

      chosen_title = result[:reply].presence || content[0..40]
      update!(title: chosen_title.strip)
    rescue => e
      Rails.logger.warn("Failed to generate title: #{e.message}")
      update!(title: content[0..40])
    end
  end
end
