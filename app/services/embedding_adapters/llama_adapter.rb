require "net/http"
require "json"
require "uri"

module EmbeddingAdapters
  class LlamaAdapter < BaseAdapter
    # Requested when POSTing to /v1/embeddings. llama.cpp ignores this and
    # embeds with whatever model is currently loaded, then echoes a model
    # identifier back in the response — that echoed value is what we store.
    REQUEST_MODEL_HINT = "default".freeze

    MAX_RETRIES = 3
    RETRYABLE_ERRORS = [
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EPIPE,
      Net::ReadTimeout,
      Net::OpenTimeout,
      IOError
    ].freeze

    def initialize(model: nil, base_url: nil)
      @model_hint = model || ENV["EMBEDDING_MODEL"] || REQUEST_MODEL_HINT
      @base_url = base_url || ENV["EMBEDDING_API_URL"] || ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
    end

    def embed(text:)
      json = post_embeddings(text.to_s)
      vector = json.dig("data", 0, "embedding")
      raise "Llama Embedding Error: malformed response (no data[0].embedding)" unless vector.is_a?(Array)
      { vector: vector, model: resolve_model_id(json) }
    end

    # Serial loop rather than a single array-input POST. Our local llama.cpp
    # drops the connection (EOFError before any HTTP status line) when it sees
    # an array `input`, so we call once per text. The batch interface stays in
    # place for a future server that actually supports array inputs.
    def embed_batch(texts:)
      texts.map { |text| embed(text: text) }
    end

    private

    # POST to /v1/embeddings. Handles two failure modes independently:
    #   1. Transient socket errors (EOFError, reset, etc.) — retry with backoff.
    #   2. "input too large" 500s — shrink the text by 25% and try again.
    #      This is a fallback for token-dense content; the clean fix is
    #      restarting llama-server with -ub 2048.
    def post_embeddings(input)
      uri = URI("#{@base_url}/embeddings")
      current_input = input

      # Outer loop: up to 3 truncation passes on "too large" errors.
      4.times do |truncation_attempt|
        response = http_post_with_retry(uri, current_input)

        if response.is_a?(Net::HTTPSuccess)
          return JSON.parse(response.body)
        end

        body = response.body.to_s

        if response.code == "500" && body.include?("too large to process") &&
            truncation_attempt < 3 && current_input.is_a?(String)
          current_input = current_input[0, (current_input.length * 0.75).to_i]
          Rails.logger.warn("Llama Embedding: input too large, truncating to #{current_input.length} chars (pass #{truncation_attempt + 1})")
          next
        end

        Rails.logger.error("Llama Embedding Error: #{response.code} #{body}")
        raise "Llama Embedding Error: #{response.code} - #{response.message}"
      end

      raise "Llama Embedding Error: input still too large after 3 truncation passes"
    end

    # Fire a single HTTP POST, retrying on transient socket errors with
    # exponential backoff (1s, 2s, 4s). Returns the Net::HTTPResponse.
    def http_post_with_retry(uri, input)
      payload = { model: @model_hint, input: input }
      attempt = 0

      begin
        attempt += 1
        http = Net::HTTP.new(uri.host, uri.port)
        http.read_timeout = 300
        http.open_timeout = 30

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer unused"
        request.body = payload.to_json

        http.request(request)
      rescue *RETRYABLE_ERRORS => e
        if attempt < MAX_RETRIES
          sleep_for = 2**(attempt - 1)
          Rails.logger.warn("Llama Embedding retry #{attempt}/#{MAX_RETRIES} after #{e.class}: #{e.message} (sleeping #{sleep_for}s)")
          sleep(sleep_for)
          retry
        end
        raise
      end
    end

    def resolve_model_id(json)
      # llama.cpp echoes the loaded model identifier here when known; fall
      # back to the hint if the server returns something empty or generic.
      reported = json["model"].to_s
      reported.presence || ENV["EMBEDDING_MODEL"].presence || @model_hint
    end
  end
end
