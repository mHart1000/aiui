module EmbeddingAdapters
  class OpenaiAdapter < BaseAdapter
    DEFAULT_MODEL = "text-embedding-3-small".freeze

    def initialize(model: nil, client: nil)
      @model = model || ENV["EMBEDDING_MODEL"].presence || DEFAULT_MODEL
      @client = client
    end

    def embed(text:)
      response = client.embeddings(parameters: { model: @model, input: text.to_s })
      vector = response.dig("data", 0, "embedding")
      raise "OpenAI Embedding Error: malformed response (no data[0].embedding)" unless vector.is_a?(Array)
      { vector: vector, model: @model }
    end

    def embed_batch(texts:)
      texts.map { |text| embed(text: text) }
    end

    private

    def client
      @client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY") {
        raise "OpenaiAdapter: OPENAI_API_KEY is not set"
      })
    end
  end
end
