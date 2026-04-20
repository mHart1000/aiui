module AiAdapters
  class OpenrouterAdapter < BaseAdapter
    OPENROUTER_URI = "https://openrouter.ai/api/v1"

    def chat(messages:, stream: false, max_tokens: nil, &block)
      client = OpenAI::Client.new(
        access_token: ENV["OPENROUTER_API_KEY"],
        uri_base: OPENROUTER_URI,
        extra_headers: openrouter_headers
      )

      # Strip the "openrouter/" prefix if present
      model_name = @model.sub(/^openrouter\//, "")
      Rails.logger.info("OpenRouter: requesting model '#{model_name}'")

      if stream
        params = {
          model: model_name,
          messages: messages,
          stream: proc do |chunk, _bytesize|
            content = chunk.dig("choices", 0, "delta", "content")
            yield content if content
          end
        }
        params[:max_tokens] = max_tokens if max_tokens
        client.chat(parameters: params)
      else
        params = {
          model: model_name,
          messages: messages
        }
        params[:max_tokens] = max_tokens if max_tokens
        response = client.chat(parameters: params)

        {
          content: response.dig("choices", 0, "message", "content"),
          tokens: extract_token_usage(response)
        }
      end
    end

    private

    def openrouter_headers
      headers = {}
      headers["HTTP-Referer"] = ENV["OPENROUTER_REFERER"] if ENV["OPENROUTER_REFERER"]
      headers["X-Title"] = ENV["OPENROUTER_TITLE"] || "AIUI"
      headers
    end

    def extract_token_usage(response)
      usage = response.dig("usage") || {}
      {
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      }
    end
  end
end
