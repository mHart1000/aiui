class OpenaiChatService
  include HTTParty
  base_uri "https://api.openai.com/v1"

  MODEL = "gpt-4o-2024-08-06" # explicitly version-locked

  def self.call(message)
    headers = {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{ENV["OPENAI_API_KEY"]}"
    }

    body = {
      model: MODEL,
      messages: [
        { role: "system", content: "You are a helpful assistant." },
        { role: "user", content: message }
      ]
    }.to_json

    begin
      res = post("/chat/completions", headers: headers, body: body)
      if res.success?
        reply = res.parsed_response.dig("choices", 0, "message", "content")
        { reply: reply }
      else
        { error: res.parsed_response }
      end
    rescue => e
      { error: e.message }
    end
  end
end
