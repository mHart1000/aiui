require "test_helper"

class Rag::RetrieverTest < ActiveSupport::TestCase
  MODEL_ID = "test-embedder-v1".freeze

  setup do
    unless ActiveRecord::Base.connection.extension_enabled?("vector")
      skip "pgvector extension not installed"
    end
    @user = User.create!(email: "retriever_#{SecureRandom.hex(4)}@example.com", password: "password123")
    @other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  test "returns chunks in nearest-neighbor order, scoped to user" do
    doc = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "a.txt")
    other_doc = RagDocument.create!(user: @other, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "b.txt")

    target_vec = one_hot(0)
    near_vec = one_hot(0, noise: 0.01)
    far_vec = one_hot(1000)

    near = RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "near", chunk_index: 0, embedding: near_vec, embedding_model: MODEL_ID)
    far = RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "far", chunk_index: 1, embedding: far_vec, embedding_model: MODEL_ID)
    RagChunk.create!(rag_document: other_doc, user: @other, source_type: "personalization", content: "other user", chunk_index: 0, embedding: near_vec, embedding_model: MODEL_ID)

    EmbeddingService.stub(:embed, ->(text:) { { vector: target_vec, model: MODEL_ID } }) do
      results = Rag::Retriever.call(user: @user, query: "anything", limit: 5)
      assert_equal [ near.id, far.id ], results.map(&:id)
    end
  end

  test "excludes chunks with nil embedding" do
    doc = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "a.txt")
    with_vec = RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "has vec", chunk_index: 0, embedding: one_hot(0), embedding_model: MODEL_ID)
    RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "no vec", chunk_index: 1, embedding: nil, embedding_model: MODEL_ID)

    EmbeddingService.stub(:embed, ->(text:) { { vector: one_hot(0), model: MODEL_ID } }) do
      results = Rag::Retriever.call(user: @user, query: "x")
      assert_equal [ with_vec.id ], results.map(&:id)
    end
  end

  test "respects source_type filter" do
    doc = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "a.txt")
    memory_doc = RagDocument.create!(user: @user, source_type: "memory", file_format: "txt", status: "ready", original_filename: "m.txt")
    personalization = RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "p", chunk_index: 0, embedding: one_hot(0), embedding_model: MODEL_ID)
    RagChunk.create!(rag_document: memory_doc, user: @user, source_type: "memory", content: "m", chunk_index: 0, embedding: one_hot(0), embedding_model: MODEL_ID)

    EmbeddingService.stub(:embed, ->(text:) { { vector: one_hot(0), model: MODEL_ID } }) do
      results = Rag::Retriever.call(user: @user, query: "x", source_types: [ "personalization" ])
      assert_equal [ personalization.id ], results.map(&:id)
    end
  end

  test "excludes chunks embedded by a different model" do
    doc = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "a.txt")
    current = RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "current model", chunk_index: 0, embedding: one_hot(0), embedding_model: MODEL_ID)
    # A stale chunk from a previous embedder with a different dimension would
    # otherwise blow up the cosine comparison at query time.
    RagChunk.create!(rag_document: doc, user: @user, source_type: "personalization", content: "stale", chunk_index: 1, embedding: Array.new(512, 0.5), embedding_model: "old-embedder")

    EmbeddingService.stub(:embed, ->(text:) { { vector: one_hot(0), model: MODEL_ID } }) do
      results = Rag::Retriever.call(user: @user, query: "x")
      assert_equal [ current.id ], results.map(&:id)
    end
  end

  test "blank query returns empty array without calling embedding service" do
    EmbeddingService.stub(:embed, ->(**_) { raise "should not be called" }) do
      assert_equal [], Rag::Retriever.call(user: @user, query: "")
      assert_equal [], Rag::Retriever.call(user: @user, query: "   ")
    end
  end

  private

  def one_hot(index, noise: 0.0)
    v = Array.new(2048, 0.0)
    v[index % 2048] = 1.0
    v[(index + 1) % 2048] = noise if noise != 0.0
    v
  end
end
