require "net/http"
require "json"
require "uri"

module EmbeddingAdapters
  class LlamaAdapter < BaseAdapter
    # Requested when POSTing to /v1/embeddings. llama.cpp ignores this and
    # embeds with whatever model is currently loaded, then echoes a model
    # identifier back in the response — that echoed value is what we store.
    REQUEST_MODEL_HINT = "default".freeze

    def initialize(model: nil, base_url: nil)
      @model_hint = model || ENV["EMBEDDING_MODEL"] || REQUEST_MODEL_HINT
      @base_url = base_url || ENV["EMBEDDING_API_URL"] || ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
    end

    def embed(text:)
      uri = URI("#{@base_url}/embeddings")
      payload = { model: @model_hint, input: text }

      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer unused"
      request.body = payload.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Llama Embedding Error: #{response.code} #{response.body}")
        raise "Llama Embedding Error: #{response.code} - #{response.message}"
      end

      json = JSON.parse(response.body)
      vector = json.dig("data", 0, "embedding")
      raise "Llama Embedding Error: malformed response (no data[0].embedding)" unless vector.is_a?(Array)

      # llama.cpp echoes the loaded model identifier here when known; fall
      # back to the hint if the server returns something empty or generic.
      reported = json["model"].to_s
      model_id = reported.presence || ENV["EMBEDDING_MODEL"].presence || @model_hint
      { vector: vector, model: model_id }
    end
  end
end
