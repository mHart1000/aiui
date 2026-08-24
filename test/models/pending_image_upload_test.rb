require "test_helper"

class PendingImageUploadTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "pending-model@example.com", password: "password123")
    @blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(File.binread(file_fixture("small.png"))),
      filename: "small.png",
      content_type: "image/png",
      identify: false
    )
  end

  test "row existence represents an owned pending upload" do
    pending = @user.pending_image_uploads.create!(blob: @blob, expires_at: 24.hours.from_now)

    assert_equal @user, pending.user
    assert_equal @blob, pending.blob
    assert_not pending.expired?
  end

  test "signed IDs are purpose scoped" do
    pending = @user.pending_image_uploads.create!(blob: @blob, expires_at: 24.hours.from_now)

    assert_equal pending, PendingImageUpload.find_signed!(
      pending.client_signed_id, purpose: PendingImageUpload::SIGNED_ID_PURPOSE
    )
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      PendingImageUpload.find_signed!(pending.client_signed_id, purpose: :other_use)
    end
  end

  test "expired scope is backed by the expiry timestamp" do
    expired = @user.pending_image_uploads.create!(blob: @blob, expires_at: 1.minute.ago)
    fresh_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("fresh"), filename: "fresh.png", content_type: "image/png", identify: false
    )
    fresh = @user.pending_image_uploads.create!(blob: fresh_blob, expires_at: 1.minute.from_now)

    assert_equal [ expired.id ], PendingImageUpload.expired.pluck(:id)
    assert_not_includes PendingImageUpload.expired, fresh
  end

  test "schema has unique ownership and indexed expiry paths" do
    indexes = ActiveRecord::Base.connection.indexes(:pending_image_uploads)

    assert indexes.any? { |index| index.unique && index.columns == [ "blob_id" ] }
    assert indexes.any? { |index| index.columns == [ "expires_at" ] }
    assert indexes.any? { |index| index.columns == %w[user_id expires_at] }
  end
end
