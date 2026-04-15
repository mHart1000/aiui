class AddRagChunksHnswIndex < ActiveRecord::Migration[7.2]
  # HNSW index on rag_chunks.embedding. Replaces the no-op migration added
  # when the original embedder was Qwen3.5-35B-A3B chat (2048-dim, above
  # pgvector 0.6's 2000-dim HNSW cap). With the dedicated embedder
  # (Qwen3-Embedding-0.6B at 1024-dim), vectors fit under the cap.
  #
  # pgvector requires HNSW to be built on a column with a DECLARED fixed
  # dimension, so this migration alters `embedding` from unsized `vector`
  # to `vector(TARGET_DIMENSION)` before creating the index. TARGET_DIMENSION
  # is pinned to 1024 (Qwen3-Embedding-0.6B's output size). Harrier-OSS-v1-0.6b
  # also outputs 1024 dims, so it can be swapped in later via env var with
  # no migration change. To use an embedder at a different dimension, roll
  # back, edit TARGET_DIMENSION, and migrate again.
  #
  # Preconditions:
  #   1. All rag_chunks rows must be empty or already 1024-dim. In practice:
  #      delete existing documents through the Knowledge UI before migrating.
  #   2. The second llama.cpp instance must be configured to serve an embedder
  #      whose output dimension matches TARGET_DIMENSION.
  #
  # CREATE INDEX CONCURRENTLY requires disable_ddl_transaction!.
  disable_ddl_transaction!

  TARGET_DIMENSION = 1024

  def up
    execute "ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE vector(#{TARGET_DIMENSION})"

    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS index_rag_chunks_embedding_hnsw
      ON rag_chunks
      USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_rag_chunks_embedding_hnsw"
    execute "ALTER TABLE rag_chunks ALTER COLUMN embedding TYPE vector"
  end
end
