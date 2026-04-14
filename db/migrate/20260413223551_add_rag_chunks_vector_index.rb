class AddRagChunksVectorIndex < ActiveRecord::Migration[7.2]
  def change
    add_index :rag_chunks, :embedding,
              using: :hnsw,
              opclass: :vector_cosine_ops,
              name: "index_rag_chunks_on_embedding_hnsw"
  end
end
