class Conversation < ApplicationRecord
  PLACEHOLDER_TITLE = "New Chat".freeze

  has_many :messages, dependent: :destroy
  belongs_to :user

  def entitle_async(content)
    return unless messages.empty?
    ConversationEntitleJob.perform_later(id, content)
  end

  def messages_for_ai
    messages.order(:created_at).map { |m| { role: m.role, content: m.content } }
  end

  def apply_model_code(requested_code)
    validated = requested_code if AI_MODELS.map { |m| m["id"] }.include?(requested_code)
    resolved = validated || model_code
    update!(model_code: resolved) if model_code != resolved
    resolved
  end

  def add_assistant_message(reply:, thinking:, tokens:)
    if tokens&.dig(:planning) && tokens&.dig(:execution)
      total_prompt = tokens[:planning][:prompt_tokens] + tokens[:execution][:prompt_tokens]
      total_completion = tokens[:planning][:completion_tokens] + tokens[:execution][:completion_tokens]
      total_all = tokens[:total]
    else
      total_prompt = tokens&.dig(:prompt_tokens) || 0
      total_completion = tokens&.dig(:completion_tokens) || 0
      total_all = tokens&.dig(:total_tokens) || 0
    end

    messages.create!(
      role: "assistant",
      content: reply,
      thinking: thinking,
      prompt_tokens: total_prompt,
      completion_tokens: total_completion,
      total_tokens: total_all
    )
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
        model: model_code,
        use_persona: false,
        use_scaffolding: false,
        max_tokens: 20
      )

      chosen_title = result[:reply].presence || content[0..40]
      update!(title: chosen_title.strip)
    rescue => e
      Rails.logger.warn("Failed to generate title: #{e.message}")
      update!(title: content[0..40])
    end
  end
end
