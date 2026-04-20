module AiAdapters
  class OpenaiAdapter < BaseAdapter
    def chat(messages:, stream: false, max_tokens: nil, &block)
      client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

      if stream
        params = {
          model: @model,
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
          model: @model,
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
