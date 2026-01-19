class OpenaiChatService
  FALLBACK_MODEL = "gpt-4o-2024-08-06"
  PERSONA_PATH = Rails.root.join("persona", "persona1.md")

  def self.enabled?
    ENV["OPENAI_ENABLED"] != "false"
  end

  def self.call(messages:, model: nil, use_persona: false)
    Rails.logger.info("OpenAI model #{model || 'none'} called with #{messages.size} messages")
    Rails.logger.debug("Messages: #{messages.inspect}")
    unless enabled?
      return "[DEV MODE] Assistant reply placeholder" if messages.empty?
      last_content = messages.last[:content].to_s
      return { reply: "[DEV MODE] Echo: #{last_content}" }
    end
    model_id = model.presence || FALLBACK_MODEL

    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

    messages_to_send = use_persona ? prepend_persona(messages) : messages

    begin
      response = client.chat(
        parameters: {
          model: model_id,
          messages: messages_to_send
        }
      )

      reply = response.dig("choices", 0, "message", "content")
      { reply: reply }
    rescue => e
      { error: e.message }
    end
  end

  private

  def self.prepend_persona(messages)
    return messages if messages.first&.dig(:role) == "system"

    persona_content = File.read(PERSONA_PATH)
    [{ role: "system", content: persona_content }] + messages
  end
end
