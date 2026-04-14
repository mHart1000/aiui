class AddRagChunksVectorIndex < ActiveRecord::Migration[7.2]
  # Intentionally a no-op for this pass.
  #
  # pgvector 0.6.0 (Ubuntu postgresql-16-pgvector) caps HNSW at 2000 dimensions,
  # and our Qwen embeddings are 2048-dim. Exact sequential scan via
  # nearest_neighbors is acceptable for a personal single-user RAG.
  #
  # Future upgrade path (when corpus size warrants it):
  #   1. Build pgvector 0.7+ from source and ALTER EXTENSION vector UPDATE.
  #   2. Keep the stored column as vector(2048); add an expression HNSW index
  #      on embedding::halfvec(2048) with halfvec_cosine_ops. halfvec supports
  #      HNSW up to 4000 dimensions with negligible recall loss for cosine.
  #   3. Update Rag::Retriever to order by the cast expression so the planner
  #      uses the index.
  def change
  end
end
