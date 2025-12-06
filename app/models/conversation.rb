class Conversation < ApplicationRecord
  has_many :messages, dependent: :destroy
  belongs_to :user

  def entitle(content)
    result = OpenaiChatService.call(
      messages: [
        { role: "system", content: "Generate a short 3-6 word chat title in the style of an article title, based on the following user message. No punctuation." },
        { role: "user", content: content }
      ],
      model: "gpt-5-nano"
    )

    title = result[:reply].presence || content[0..40]
    update!(title: title.strip)
  end
end
