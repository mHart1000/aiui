class OpenaiChatService
  FALLBACK_MODEL = "gpt-4o-2024-08-06"

  def self.call(messages:, model: nil)
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
