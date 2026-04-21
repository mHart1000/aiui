require "test_helper"

module Api
  class RagDocumentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "rag_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
    end

    test "index returns only current user's documents" do
      mine = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "mine.txt", title: "mine")
      other_user = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
      RagDocument.create!(user: other_user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "theirs.txt", title: "theirs")

      get "/api/rag_documents", headers: @headers
      assert_response :success
      body = JSON.parse(response.body)
      ids = body.map { |d| d["id"] }
      assert_includes ids, mine.id
      assert_equal 1, ids.length
    end

    test "create accepts a txt upload and enqueues ingestion" do
      file = Tempfile.new([ "fixture", ".txt" ])
      file.write("some sample text")
      file.rewind
      uploaded = Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "fixture.txt")

      job_args = nil
      RagIngestionJob.stub(:perform_later, ->(*args) { job_args = args }) do
        post "/api/rag_documents", params: { file: uploaded }, headers: @headers
      end
      assert_response :created

      body = JSON.parse(response.body)
      doc = RagDocument.find(body["id"])
      assert_equal @user.id, doc.user_id
      assert_equal "txt", doc.file_format
      assert_equal "pending", doc.status
      assert_equal doc.id, job_args[0]
      assert File.exist?(job_args[1]), "expected persisted upload at #{job_args[1]}"
      File.delete(job_args[1]) if File.exist?(job_args[1])
    ensure
      file&.close
      file&.unlink
    end

    test "create rejects unsupported formats" do
      file = Tempfile.new([ "fixture", ".xlsx" ])
      file.write("binary junk")
      file.rewind
      uploaded = Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "fixture.xlsx")

      RagIngestionJob.stub(:perform_later, ->(*_) { raise "should not enqueue" }) do
        post "/api/rag_documents", params: { file: uploaded }, headers: @headers
      end
      assert_response :unprocessable_entity
    ensure
      file&.close
      file&.unlink
    end

    test "destroy removes the document and cascades chunks" do
      doc = RagDocument.create!(user: @user, source_type: "personalization", file_format: "txt", status: "ready", original_filename: "del.txt")
      # No vector column touched here — chunk-level cascade is what matters
      doc.rag_chunks.create!(user: @user, source_type: "personalization", content: "c1", chunk_index: 0)

      delete "/api/rag_documents/#{doc.id}", headers: @headers
      assert_response :no_content
      assert_nil RagDocument.find_by(id: doc.id)
      assert_equal 0, RagChunk.where(rag_document_id: doc.id).count
    end
  end
end
