require "test_helper"

class ImageAttachmentClaimConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    cleanup_records
    @user = User.create!(email: "image-race@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Race")
    @blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(File.binread(file_fixture("small.png"))),
      filename: "small.png",
      content_type: "image/png",
      identify: false
    )
  end

  def teardown
    cleanup_records
  end

  test "two concurrent claims produce exactly one message" do
    token = @blob.signed_id
    ready = Queue.new
    start = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          controller = Api::MessagesController.new
          ready << true
          start.pop

          begin
            conversation = Conversation.find(@conversation.id)
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
    assert_equal 1, results.count("attachment_already_used")
    assert_equal 1, @conversation.messages.count
    assert_equal @blob.id, @conversation.messages.first.images_attachments.first.blob_id
  end

  private

  def cleanup_records
    ActiveStorage::Attachment.delete_all
    Message.delete_all
    Conversation.delete_all
    ActiveStorage::Blob.delete_all
    Skill.delete_all
    User.delete_all
  end
end
