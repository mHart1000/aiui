class CreateRagTables < ActiveRecord::Migration[7.2]
  def change
    enable_extension "vector"

    create_table :rag_documents do |t|
      t.references :user, null: false, foreign_key: true
      t.string :source_type, null: false, default: "personalization"
      t.string :title
      t.string :original_filename
      t.string :file_format
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.string :embedding_model
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end
    add_index :rag_documents, [ :user_id, :source_type ]

    create_table :rag_chunks do |t|
      t.references :rag_document, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :source_type, null: false
      t.text :content, null: false
      t.integer :chunk_index, null: false
      t.column :embedding, :vector
      t.string :embedding_model
      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end
    add_index :rag_chunks, [ :user_id, :source_type ]
    add_index :rag_chunks, [ :user_id, :source_type, :embedding_model ],
              name: "index_rag_chunks_on_user_source_model"
  end
end
