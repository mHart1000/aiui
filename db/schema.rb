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

ActiveRecord::Schema[8.1].define(version: 2026_08_13_085258) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "model_code"
    t.boolean "rag_enabled", default: false, null: false
    t.jsonb "skill_ids"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "use_skills"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "completion_tokens"
    t.text "content", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "generation_ms"
    t.string "persona_version"
    t.integer "prompt_tokens"
    t.string "role", null: false
    t.jsonb "skill_versions"
    t.text "thinking"
    t.float "tokens_per_second"
    t.integer "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "rag_chunks", force: :cascade do |t|
    t.integer "chunk_index", null: false
    t.text "content", null: false
    t.virtual "content_tsv", type: :tsvector, as: "to_tsvector('english'::regconfig, content)", stored: true
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1024
    t.string "embedding_model"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "rag_document_id", null: false
    t.string "source_type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["content_tsv"], name: "index_rag_chunks_on_content_tsv", using: :gin
    t.index ["embedding"], name: "index_rag_chunks_embedding_hnsw", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["rag_document_id"], name: "index_rag_chunks_on_rag_document_id"
    t.index ["user_id", "source_type", "embedding_model"], name: "index_rag_chunks_on_user_source_model"
    t.index ["user_id", "source_type"], name: "index_rag_chunks_on_user_id_and_source_type"
    t.index ["user_id"], name: "index_rag_chunks_on_user_id"
  end

  create_table "rag_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "embedding_model"
    t.text "error_message"
    t.string "file_format"
    t.jsonb "metadata", default: {}, null: false
    t.string "original_filename"
    t.string "source_type", default: "personalization", null: false
    t.string "status", default: "pending", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "source_type"], name: "index_rag_documents_on_user_id_and_source_type"
    t.index ["user_id"], name: "index_rag_documents_on_user_id"
  end

  create_table "skills", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.boolean "enabled_by_default", default: false, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "name"], name: "index_skills_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_skills_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "image_max_pixels", default: 6000000
    t.integer "llama_context_window", default: 8192
    t.string "persona_id", default: "persona1", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.boolean "tts_enabled", default: false, null: false
    t.float "tts_speed", default: 1.0
    t.string "tts_voice"
    t.datetime "updated_at", null: false
    t.boolean "use_persona", default: true, null: false
    t.boolean "use_scaffolding", default: true, null: false
    t.boolean "use_skills", default: false, null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "conversations", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "rag_chunks", "rag_documents"
  add_foreign_key "rag_chunks", "users"
  add_foreign_key "rag_documents", "users"
  add_foreign_key "skills", "users"
end
