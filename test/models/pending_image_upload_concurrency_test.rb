require "test_helper"

class PendingImageUploadConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    cleanup_records
    @user = User.create!(email: "pending-race@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Race")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(File.binread(file_fixture("small.png"))),
      filename: "small.png",
      content_type: "image/png",
      identify: false
    )
    @pending = @user.pending_image_uploads.create!(blob: blob, expires_at: 1.hour.from_now)
  end

  def teardown
    cleanup_records
  end

  test "two concurrent claims produce exactly one message" do
    token = @pending.client_signed_id
    ready = Queue.new
    start = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          controller = Api::MessagesController.new
          user = User.find(@user.id)
          controller.define_singleton_method(:current_api_user) { user }
          ready << true
          start.pop

          begin
            conversation = user.conversations.find(@conversation.id)
            controller.send(:create_user_message!, conversation, "race", [ token ])
            :claimed
          rescue Api::MessagesController::RequestError => e
            e.code
          end
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    assert_equal 1, results.count(:claimed)
    assert_equal 1, results.count("attachment_not_found")
    assert_equal 1, @conversation.messages.count
    assert_not PendingImageUpload.exists?(@pending.id)
  end

  test "deleting a user removes pending rows and their unattached blobs" do
    pending_id = @pending.id
    blob_id = @pending.blob_id

    @user.destroy!

    assert_not PendingImageUpload.exists?(pending_id)
    assert_not ActiveStorage::Blob.exists?(blob_id)
  end

  private

  def cleanup_records
    PendingImageUpload.delete_all
    ActiveStorage::Attachment.delete_all
    Message.delete_all
    Conversation.delete_all
    ActiveStorage::Blob.delete_all
    Skill.delete_all
    User.delete_all
  end
end
