require "test_helper"
require "rake"

class AttachmentsTaskTest < ActiveSupport::TestCase
  def setup
    Rails.application.load_tasks unless Rake::Task.task_defined?("attachments:purge_expired")
    @user = User.create!(email: "attachment-task@example.com", password: "password123")
  end

  def pending(expires_at:, filename:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(filename), filename: filename, content_type: "image/png", identify: false
    )
    @user.pending_image_uploads.create!(blob: blob, expires_at: expires_at)
  end

  def invoke_task(name, env = {})
    task = Rake::Task[name]
    task.reenable
    with_env(env) { capture_io { task.invoke } }
  end

  test "dry run reports expired rows without deleting them" do
    expired = pending(expires_at: 1.hour.ago, filename: "expired.png")
    fresh = pending(expires_at: 1.hour.from_now, filename: "fresh.png")

    stdout, = invoke_task("attachments:purge_expired", "DRY_RUN" => "1")

    assert_includes stdout, "Would purge 1"
    assert PendingImageUpload.exists?(expired.id)
    assert PendingImageUpload.exists?(fresh.id)
  end

  test "real cleanup deletes only expired pending rows" do
    expired = pending(expires_at: 1.hour.ago, filename: "expired.png")
    fresh = pending(expires_at: 1.hour.from_now, filename: "fresh.png")

    stdout, = invoke_task("attachments:purge_expired", "DRY_RUN" => nil)

    assert_includes stdout, "Purging 1"
    assert_not PendingImageUpload.exists?(expired.id)
    assert PendingImageUpload.exists?(fresh.id)
  end

  test "legacy audit is report-only" do
    legacy = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("legacy"), filename: "legacy.png", content_type: "image/png", identify: false
    )
    legacy.update_column(:created_at, Time.zone.parse("2026-08-22"))

    stdout, = invoke_task("attachments:audit_legacy_unattached")

    assert_includes stdout, "no files were deleted"
    assert ActiveStorage::Blob.exists?(legacy.id)
  end
end
