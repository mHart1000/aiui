require "net/http"
require "json"
require "uri"

module AiAdapters
  class AnthropicAdapter < BaseAdapter
    BASE_URL = "https://api.anthropic.com/v1/messages"
    API_VERSION = "2023-06-01"
    MAX_TOKENS = 16000

    def chat(messages:, stream: false, max_tokens: nil, &block)
      api_key = ENV["ANTHROPIC_API_KEY"]
      raise "ANTHROPIC_API_KEY is not set" unless api_key

      system_message = messages.find { |m| m[:role] == "system" }&.dig(:content)
      filtered_messages = messages.reject { |m| m[:role] == "system" }

      payload = {
        model: @model,
        max_tokens: max_tokens || MAX_TOKENS,
        messages: filtered_messages,
        stream: stream
      }
      payload[:system] = system_message if system_message

      uri = URI(BASE_URL)
      headers = {
        "Content-Type" => "application/json",
        "x-api-key" => api_key,
        "anthropic-version" => API_VERSION
      }

      if stream
        perform_streaming_request(uri, headers, payload, &block)
      else
        perform_blocking_request(uri, headers, payload)
      end
    end

    private

    def perform_blocking_request(uri, headers, payload)
      response = Net::HTTP.post(uri, payload.to_json, headers)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Anthropic API Error: #{response.body}")
        raise "Anthropic API Error: #{response.code} - #{response.message}"
      end

      json = JSON.parse(response.body)
      content = json.dig("content", 0, "text") || ""
      usage = json.dig("usage") || {}
      prompt = usage["input_tokens"] || 0
      completion = usage["output_tokens"] || 0

      {
        content: content,
        tokens: {
          prompt_tokens: prompt,
          completion_tokens: completion,
          total_tokens: prompt + completion
        }
      }
    end

    def perform_streaming_request(uri, headers, payload)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri)
        headers.each { |k, v| request[k] = v }
        request.body = payload.to_json

        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            body = response.read_body
            Rails.logger.error("Anthropic Streaming Error: #{body}")
            raise "Anthropic API Error: #{response.code} - #{response.message}"
          end

          buffer = ""
          response.read_body do |chunk|
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next if line.empty? || line.start_with?("event:")

              if line.start_with?("data: ")
                json_str = line.sub("data: ", "")
                begin
                  data = JSON.parse(json_str)
                  if data["type"] == "content_block_delta" &&
                     data.dig("delta", "type") == "text_delta"
                    text = data.dig("delta", "text")
                    yield text if text
                  end
                rescue JSON::ParserError
                  # Partial or non-JSON line, skip
                end
              end
            end
          end
        end
      end
    end
  end
end
