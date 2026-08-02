require "net/http"
require "json"
require "uri"

module RerankerAdapters
  class LlamaAdapter < BaseAdapter
    # Sent as the `model` field on /v1/rerank requests. llama.cpp ignores it
    # and echoes it back, same as the embeddings endpoint. Real identity is
    # resolved from /v1/models via #resolve_model_id.
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
      @explicit_model = model || ENV["RERANKER_MODEL"].presence
      @base_url = base_url || ENV["RERANKER_API_URL"] || "http://host.docker.internal:8092/v1"
      @resolved_model_id = nil
    end

    # Calls /v1/rerank and returns [{ index:, score:, model: }, ...] sorted by
    # score descending. The caller supplies `query` and `documents` (an Array
    # of Strings); llama.cpp applies the reranker's prompt template server-side
    # (including the task instruction if set via --system-prompt at startup).
    def rerank(query:, documents:)
      return [] if documents.nil? || documents.empty?

      json = post_rerank(query.to_s, documents.map(&:to_s))
      results = json["results"]
      raise "Llama Rerank Error: malformed response (no results array)" unless results.is_a?(Array)

      model_id = resolve_model_id
      parsed = results.map do |r|
        idx = r["index"]
        score = r["relevance_score"] || r.dig("document", "relevance_score")
        unless idx.is_a?(Integer) && score.is_a?(Numeric)
          raise "Llama Rerank Error: malformed result entry #{r.inspect}"
        end
        { index: idx, score: score.to_f, model: model_id }
      end
      parsed.sort_by { |r| -r[:score] }
    end

    private

    def post_rerank(query, documents)
      uri = URI("#{@base_url}/rerank")
      response = http_post_with_retry(uri, query, documents)

      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      Rails.logger.error("Llama Rerank Error: #{response.code} #{response.body.to_s[0, 500]}")
      raise "Llama Rerank Error: #{response.code} - #{response.message}"
    end

    def http_post_with_retry(uri, query, documents)
      payload = { model: REQUEST_MODEL_HINT, query: query, documents: documents }
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
          Rails.logger.warn("Llama Rerank retry #{attempt}/#{MAX_RETRIES} after #{e.class}: #{e.message} (sleeping #{sleep_for}s)")
          sleep(sleep_for)
          retry
        end
        Rails.logger.error("Llama Rerank failed after #{MAX_RETRIES} retries: #{e.class}: #{e.message}")
        raise
      end
    end

    # Canonical identity of the reranker model. Priority mirrors LlamaAdapter:
    #   1. Explicit `model:` constructor argument
    #   2. RERANKER_MODEL env var
    #   3. Auto-detect from llama.cpp /v1/models (cached per adapter)
    def resolve_model_id
      return @resolved_model_id if @resolved_model_id
      @resolved_model_id = @explicit_model.presence || fetch_server_model_id
      if @resolved_model_id.to_s.empty?
        raise "Llama Rerank Error: could not determine reranker model identity. " \
              "Set RERANKER_MODEL env var or ensure llama-server /v1/models returns a model id."
      end
      Rails.logger.info("RerankerAdapters::LlamaAdapter: resolved reranker_model = #{@resolved_model_id.inspect}")
      @resolved_model_id
    end

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
      Rails.logger.warn("RerankerAdapters::LlamaAdapter: /v1/models lookup failed (#{e.class}: #{e.message})")
      nil
    end
  end
end
