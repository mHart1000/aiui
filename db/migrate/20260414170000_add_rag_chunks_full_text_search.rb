class AddRagChunksFullTextSearch < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      ALTER TABLE rag_chunks
      ADD COLUMN content_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
    SQL
    add_index :rag_chunks, :content_tsv, using: :gin
  end

  def down
    remove_index :rag_chunks, :content_tsv
    remove_column :rag_chunks, :content_tsv
  end
end
