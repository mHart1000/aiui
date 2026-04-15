require "net/http"
require "json"
require "uri"

module EmbeddingAdapters
  class LlamaAdapter < BaseAdapter
    # Sent as the `model` field on /v1/embeddings requests. llama.cpp ignores
    # it and just echoes it back verbatim, so it has no effect on which model
    # actually runs — it's only present because OpenAI-compatible clients
    # expect the field. The real model identity comes from #resolve_model_id.
    REQUEST_MODEL_HINT = "default".freeze

    MAX_RETRIES = 5
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
      @explicit_model = model || ENV["EMBEDDING_MODEL"].presence
      @base_url = base_url || ENV["EMBEDDING_API_URL"] || ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
      @resolved_model_id = nil
    end

    def embed(text:)
      json = post_embeddings(text.to_s)
      vector = json.dig("data", 0, "embedding")
      raise "Llama Embedding Error: malformed response (no data[0].embedding)" unless vector.is_a?(Array)
      { vector: vector, model: resolve_model_id }
    end

    # Serial loop rather than a single array-input POST. Our local llama.cpp
    # drops the connection (EOFError before any HTTP status line) when it sees
    # an array `input`, so we call once per text. The batch interface stays in
    # place for a future server that actually supports array inputs.
    def embed_batch(texts:)
      texts.map.with_index { |text, idx|
        Rails.logger.debug("Embedding chunk #{idx + 1}/#{texts.length} (#{text.length} chars)")
        embed(text: text)
      }
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
          Rails.logger.debug("Embedding succeeded (#{current_input.length} chars)")
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
        Rails.logger.error("Llama Embedding failed after #{MAX_RETRIES} retries: #{e.class}: #{e.message}")
        raise
      end
    end

    # The canonical identity of the embedding model, used as the stored
    # `embedding_model` value on every chunk. Vectors from different models
    # live in different spaces (and often different dimensions) so this value
    # MUST be stable — otherwise Rag::Retriever can't isolate compatible
    # chunks and you get silent cross-model contamination.
    #
    # Priority:
    #   1. Explicit `model:` constructor argument
    #   2. EMBEDDING_MODEL env var
    #   3. Auto-detect from llama.cpp /v1/models endpoint (cached per adapter)
    #
    # Raises if none of the above yields a non-empty identifier.
    def resolve_model_id
      return @resolved_model_id if @resolved_model_id
      @resolved_model_id = @explicit_model.presence || fetch_server_model_id
      if @resolved_model_id.to_s.empty?
        raise "Llama Embedding Error: could not determine embedding model identity. " \
              "Set EMBEDDING_MODEL env var or ensure llama-server /v1/models returns a model id."
      end
      Rails.logger.info("LlamaAdapter: resolved embedding_model = #{@resolved_model_id.inspect}")
      @resolved_model_id
    end

    # Query llama.cpp's /v1/models endpoint to discover the currently-loaded
    # model filename. Returns nil on any failure — callers decide whether
    # that's fatal.
    def fetch_server_model_id
      uri = URI("#{@base_url}/models")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 10
      http.open_timeout = 5
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer unused"
      response = http.request(request)
      return nil unless response.is_a?(Net::HTTPSuccess)

      json = JSON.parse(response.body)
      json.dig("data", 0, "id").to_s.presence
    rescue => e
      Rails.logger.warn("LlamaAdapter: /v1/models lookup failed (#{e.class}: #{e.message})")
      nil
    end
  end
end
