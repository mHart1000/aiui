require "test_helper"
require "rake"

class AttachmentsTaskTest < ActiveSupport::TestCase
  def setup
    Rails.application.load_tasks unless Rake::Task.task_defined?("attachments:purge_expired")
  end

  def blob(created_at:, filename:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(filename), filename: filename, content_type: "image/png", identify: false
    )
    blob.update_column(:created_at, created_at)
    blob
  end

  def invoke_task(env = {})
    task = Rake::Task["attachments:purge_expired"]
    task.reenable
    with_env(env) { capture_io { task.invoke } }
  end

  test "dry run reports expired unattached blobs without deleting them" do
    expired = blob(created_at: 25.hours.ago, filename: "expired.png")
    fresh = blob(created_at: 23.hours.ago, filename: "fresh.png")

    stdout, = invoke_task("DRY_RUN" => "1")

    assert_includes stdout, "Would purge 1"
    assert ActiveStorage::Blob.exists?(expired.id)
    assert ActiveStorage::Blob.exists?(fresh.id)
  end

  test "real cleanup deletes only expired unattached blobs" do
    expired = blob(created_at: 25.hours.ago, filename: "expired.png")
    fresh = blob(created_at: 23.hours.ago, filename: "fresh.png")

    stdout, = invoke_task("DRY_RUN" => nil)

    assert_includes stdout, "Purging 1"
    assert_not ActiveStorage::Blob.exists?(expired.id)
    assert ActiveStorage::Blob.exists?(fresh.id)
  end

  test "cleanup retains old blobs attached to messages" do
    user = User.create!(email: "attachment-task@example.com", password: "password123")
    conversation = user.conversations.create!(title: "Saved")
    saved = blob(created_at: 25.hours.ago, filename: "saved.png")
    conversation.messages.create!(role: "user", content: "saved", images: [ saved ])

    stdout, = invoke_task

    assert_includes stdout, "Purging 0"
    assert ActiveStorage::Blob.exists?(saved.id)
  end
end
