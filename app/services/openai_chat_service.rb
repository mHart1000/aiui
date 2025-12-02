class OpenaiChatService
  FALLBACK_MODEL = "gpt-4o-2024-08-06"

  def self.enabled?
    ENV["OPENAI_ENABLED"] != "false"
  end

  def self.call(messages:, model: nil)
    unless enabled?
      return "[DEV MODE] Assistant reply placeholder" if messages.empty?
      last_content = messages.last[:content].to_s
      return { reply: "[DEV MODE] Echo: #{last_content}" }
    end
    model_id = model.presence || FALLBACK_MODEL

    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

    begin
      response = client.chat(
        parameters: {
          model: model_id,
          messages: messages
        }
      )

      reply = response.dig("choices", 0, "message", "content")
      { reply: reply }
    rescue => e
      { error: e.message }
    end
  end
end
