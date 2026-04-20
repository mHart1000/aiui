require "net/http"
require "json"
require "uri"

module EmbeddingAdapters
  class VoyageAdapter < BaseAdapter
    BASE_URL = "https://api.voyageai.com/v1".freeze
    DEFAULT_MODEL = "voyage-3-lite".freeze

    def initialize(model: nil, api_key: nil)
      @model = model || ENV["EMBEDDING_MODEL"].presence || DEFAULT_MODEL
      @api_key = api_key || ENV["VOYAGE_API_KEY"].presence
      raise "VoyageAdapter: VOYAGE_API_KEY is not set" unless @api_key
    end

    def embed(text:)
      body = post_embeddings(text.to_s)
      vector = body.dig("data", 0, "embedding")
      raise "Voyage Embedding Error: malformed response (no data[0].embedding)" unless vector.is_a?(Array)
      { vector: vector, model: @model }
    end

    def embed_batch(texts:)
      texts.map { |text| embed(text: text) }
    end

    private

    def post_embeddings(input)
      uri = URI("#{BASE_URL}/embeddings")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_key}"
      request.body = { model: @model, input: input }.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "Voyage Embedding Error: #{response.code} - #{response.message}: #{response.body.to_s[0, 500]}"
      end
      JSON.parse(response.body)
    end
  end
end
