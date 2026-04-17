# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_04_15_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"
  enable_extension "vector"

  create_table "conversations", force: :cascade do |t|
    t.string "title"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "model_code"
    t.boolean "rag_enabled", default: false, null: false
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.string "role", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "thinking"
    t.integer "prompt_tokens"
    t.integer "completion_tokens"
    t.integer "total_tokens"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "rag_chunks", force: :cascade do |t|
    t.bigint "rag_document_id", null: false
    t.bigint "user_id", null: false
    t.string "source_type", null: false
    t.text "content", null: false
    t.integer "chunk_index", null: false
    t.vector "embedding", limit: 1024
    t.string "embedding_model"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.virtual "content_tsv", type: :tsvector, as: "to_tsvector('english'::regconfig, content)", stored: true
    t.index ["content_tsv"], name: "index_rag_chunks_on_content_tsv", using: :gin
    t.index ["embedding"], name: "index_rag_chunks_embedding_hnsw", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["rag_document_id"], name: "index_rag_chunks_on_rag_document_id"
    t.index ["user_id", "source_type", "embedding_model"], name: "index_rag_chunks_on_user_source_model"
    t.index ["user_id", "source_type"], name: "index_rag_chunks_on_user_id_and_source_type"
    t.index ["user_id"], name: "index_rag_chunks_on_user_id"
  end

  create_table "rag_documents", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "source_type", default: "personalization", null: false
    t.string "title"
    t.string "original_filename"
    t.string "file_format"
    t.string "status", default: "pending", null: false
    t.text "error_message"
    t.string "embedding_model"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "source_type"], name: "index_rag_documents_on_user_id_and_source_type"
    t.index ["user_id"], name: "index_rag_documents_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "use_scaffolding", default: true, null: false
    t.boolean "tts_enabled", default: false, null: false
    t.string "tts_voice"
    t.float "tts_speed", default: 1.0
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "conversations", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "rag_chunks", "rag_documents"
  add_foreign_key "rag_chunks", "users"
  add_foreign_key "rag_documents", "users"
end
