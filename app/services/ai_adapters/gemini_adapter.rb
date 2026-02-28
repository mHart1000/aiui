require "net/http"
require "json"
require "uri"

module AiAdapters
  class GeminiAdapter < BaseAdapter
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"

    def chat(messages:, stream: false, &block)
      api_key = ENV["GEMINI_API_KEY"]
      raise "GEMINI_API_KEY is not set" unless api_key

      # Map OpenAI-style labels to Gemini format
      gemini_messages = messages.map do |msg|
        next if msg[:role] == "system"

        {
          role: msg[:role] == "user" ? "user" : "model",
          parts: [{ text: msg[:content] }]
        }
      end.compact

      system_instruction = messages.find { |m| m[:role] == "system" }&.dig(:content)

      # Determine the endpoint (streamGenerateContent or generateContent)
      method = stream ? "streamGenerateContent" : "generateContent"
      uri = URI("#{BASE_URL}/#{@model}:#{method}?key=#{api_key}")

      payload = {
        contents: gemini_messages,
        generationConfig: {
          temperature: 0.7
        }
      }

      if system_instruction
        payload[:systemInstruction] = {
          parts: [ { text: system_instruction } ]
        }
      end

      if stream
        perform_streaming_request(uri, payload, &block)
      else
        perform_blocking_request(uri, payload)
      end
    end

    private

    def perform_blocking_request(uri, payload)
      response = Net::HTTP.post(
        uri,
        payload.to_json,
        "Content-Type" => "application/json"
      )

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Gemini API Error: #{response.body}")
        raise "Gemini API Error: #{response.code} - #{response.message}"
      end

      json = JSON.parse(response.body)

      # Extract content
      content = json.dig("candidates", 0, "content", "parts", 0, "text") || ""

      # Extract usage
      usage = json.dig("usageMetadata") || {}

      {
        content: content,
        tokens: {
          prompt_tokens: usage["promptTokenCount"] || 0,
          completion_tokens: usage["candidatesTokenCount"] || 0,
          total_tokens: usage["totalTokenCount"] || 0
        }
      }
    end

    def perform_streaming_request(uri, payload)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = payload.to_json

        http.request(request) do |response|
          buffer = ""
          response.read_body do |chunk|
            # Gemini returns a JSON array stream. We buffer chunks and parse complete
            # JSON objects as they arrive to extract generated text.
            buffer += chunk
            while (first_brace = buffer.index("{")) && (last_brace = buffer.index("}"))
               if last_brace > first_brace
                 potential_json = buffer[first_brace..last_brace]
                 begin
                   data = JSON.parse(potential_json)
                   text = data.dig("candidates", 0, "content", "parts", 0, "text")
                   yield text if text
                   # Advance buffer
                   buffer = buffer[(last_brace + 1)..-1]
                 rescue JSON::ParserError
                   # If parsing fails (likely due to nested braces causing an incomplete JSON snippet),
                   # we continue buffering until we have the full object. Can build a more robust json parser if needed.
                   break
                 end
               else
                 break
               end
            end
          end
        end
      end
    end
  end
end
