require "net/http"
require "json"
require "uri"

module AiAdapters
  class LlamaAdapter < BaseAdapter
    def chat(messages:, stream: false, &block)
      base_url = ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
      uri = URI("#{base_url}/chat/completions")

      # Prepare payload compatible with OpenAI API
      payload = {
        model: @model, # e.g. "llama-3-8b"
        messages: messages,
        temperature: 0.7,
        stream: stream
      }

      if stream
        perform_streaming_request(uri, payload, &block)
      else
        perform_blocking_request(uri, payload)
      end
    end

    private

    def perform_blocking_request(uri, payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120 # Local models can be slow

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer unused" # deeply mandated by some clients, often ignored by llama.cpp
      request.body = payload.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Llama API Error: #{response.body}")
        raise "Llama API Error: #{response.code} - #{response.message}"
      end

      json = JSON.parse(response.body)

      {
        content: json.dig("choices", 0, "message", "content"),
        tokens: extract_token_usage(json)
      }
    end

    def perform_streaming_request(uri, payload)
      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer unused"
        request.body = payload.to_json

        http.request(request) do |response|
          buffer = ""
          response.read_body do |chunk|
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next if line.empty?
              next if line == "data: [DONE]"

              if line.start_with?("data: ")
                json_str = line.sub("data: ", "")
                begin
                  json = JSON.parse(json_str)
                  content = json.dig("choices", 0, "delta", "content")
                  yield content if content
                rescue JSON::ParserError
                  # Partial line or invalid JSON, ignore
                end
              end
            end
          end
        end
      end
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
