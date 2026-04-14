module Rag
  class Retriever
    DEFAULT_LIMIT = 5
    DEFAULT_SOURCE_TYPES = [ "personalization" ].freeze

    def self.call(user:, query:, source_types: DEFAULT_SOURCE_TYPES, limit: DEFAULT_LIMIT)
      new(user: user, query: query, source_types: source_types, limit: limit).call
    end

    def initialize(user:, query:, source_types:, limit:)
      @user = user
      @query = query
      @source_types = source_types
      @limit = limit
    end

    def call
      return [] if @query.to_s.strip.empty?

      result = EmbeddingService.embed(text: @query)
      query_vector = result[:vector]
      active_model = result[:model]

      # Filter by embedding_model is non-optional: pgvector raises a runtime
      # error if you compare vectors of different dimensions. Chunks embedded
      # by a previous model remain in the DB but are invisible until re-embedded.
      RagChunk
        .where(user_id: @user.id, source_type: @source_types, embedding_model: active_model)
        .with_embedding
        .nearest_neighbors(:embedding, query_vector, distance: "cosine")
        .includes(:rag_document)
        .limit(@limit)
        .to_a
    end
  end
end
