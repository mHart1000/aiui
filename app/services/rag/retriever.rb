module Rag
  class Retriever
    DEFAULT_LIMIT = 20
    DEFAULT_SOURCE_TYPES = [ "personalization" ].freeze

    # Candidate pool size pulled from each arm of the hybrid search before
    # Reciprocal Rank Fusion. Larger than DEFAULT_LIMIT so RRF has room to
    # surface chunks that rank highly in one modality but not the other, and
    # so the reranker (when enabled) has a meaningful pool to reorder.
    CANDIDATE_POOL = 40

    # RRF smoothing constant. k=60 is the commonly cited default from the
    # original paper; it damps the weight of very-top ranks just enough that
    # a chunk ranked #2 in both modalities beats one ranked #1 in only one.
    RRF_K = 60

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

      result = EmbeddingService.embed(text: embed_query_text(@query))
      query_vector = result[:vector]
      active_model = result[:model]

      vector_hits = vector_search(query_vector, active_model)
      keyword_hits = keyword_search(active_model)

      # When the reranker is enabled we pull the full candidate pool so it has
      # something to reorder. When it's off, we slice to @limit directly to
      # avoid loading chunks we'd immediately discard.
      pool_size = rerank_enabled? ? CANDIDATE_POOL : @limit
      fused_ids = reciprocal_rank_fusion(vector_hits, keyword_hits).first(pool_size)
      return [] if fused_ids.empty?

      chunks_by_id = RagChunk.where(id: fused_ids).includes(:rag_document).index_by(&:id)
      candidates = fused_ids.map { |id| chunks_by_id[id] }.compact

      rerank_candidates(candidates).first(@limit)
    end

    private

    # Instruction-tuned embedders like Qwen3-Embedding and Harrier-OSS expect
    # retrieval queries to be wrapped with a task instruction, while documents
    # pass through raw. Controlled by EMBEDDING_QUERY_INSTRUCTION — if set, the
    # query is wrapped as `Instruct: {value}\nQuery: {query}`. If unset (or
    # serving an embedder that doesn't want wrapping), queries go through raw.
    # Keyword search keeps using the unwrapped query so the instruction prefix
    # never pollutes BM25 matching.
    def embed_query_text(query)
      instruction = ENV["EMBEDDING_QUERY_INSTRUCTION"].presence
      return query unless instruction
      "Instruct: #{instruction}\nQuery: #{query}"
    end

    # Filter by embedding_model is non-optional: pgvector raises a runtime
    # error if you compare vectors of different dimensions. Chunks embedded
    # by a previous model remain in the DB but are invisible until re-embedded.
    def base_scope(active_model)
      RagChunk.where(
        user_id: @user.id,
        source_type: @source_types,
        embedding_model: active_model
      )
    end

    def vector_search(query_vector, active_model)
      base_scope(active_model)
        .where.not(embedding: nil)
        .nearest_neighbors(:embedding, query_vector, distance: "cosine")
        .limit(CANDIDATE_POOL)
        .pluck(:id)
    end

    # Full-text search via the generated tsvector column.
    #
    # We start from plainto_tsquery (which stems the query and strips English
    # stopwords), then rewrite its default AND joins to OR joins. AND is too
    # strict for natural-language questions — a chunk mentioning a specific
    # term but not every incidental word in the question would otherwise be
    # filtered out. Ranking is still driven by ts_rank_cd, so chunks matching
    # more terms still rank higher.
    def keyword_search(active_model)
      return [] if @query.to_s.strip.empty?

      tsquery_sql = "replace(plainto_tsquery('english', ?)::text, '&', '|')::tsquery"

      base_scope(active_model)
        .where("content_tsv @@ #{tsquery_sql}", @query)
        .order(Arel.sql("ts_rank_cd(content_tsv, #{tsquery_sql.sub('?', ActiveRecord::Base.connection.quote(@query))}) DESC"))
        .limit(CANDIDATE_POOL)
        .pluck(:id)
    end

    # Reciprocal Rank Fusion: score each doc as the sum of 1/(k + rank) across
    # every ranked list it appears in. This converts two heterogeneous score
    # spaces (cosine distance, ts_rank) into a single comparable ordering
    # without needing to normalise either one.
    def reciprocal_rank_fusion(*ranked_id_lists)
      scores = Hash.new(0.0)
      ranked_id_lists.each do |ids|
        ids.each_with_index do |id, idx|
          scores[id] += 1.0 / (RRF_K + idx + 1)
        end
      end
      scores.sort_by { |_id, score| -score }.map(&:first)
    end

    # Cross-encoder reranker pass. Gated by the RERANKER_ENABLED env var so
    # the user can toggle it at will. When enabled, errors propagate — the
    # higher-level rescue in Api::MessagesController#fetch_rag_context catches
    # them and continues the chat without RAG context, so reranker outages
    # surface cleanly instead of silently degrading to unreranked results.
    def rerank_candidates(chunks)
      return chunks if !rerank_enabled? || chunks.empty?

      docs = chunks.map(&:content)
      ranked_results = RerankerService.rerank(query: @query, documents: docs)
      reordered = ranked_results.map { |r| chunks[r[:index]] }.compact
      Rails.logger.info("[RAG] reranker reordered #{chunks.length} candidates")
      reordered
    end

    def rerank_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["RERANKER_ENABLED"])
    end
  end
end
