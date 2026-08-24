class PendingImageUpload < ApplicationRecord
  TTL = 24.hours
  SIGNED_ID_PURPOSE = :pending_image_upload

  belongs_to :user
  belongs_to :blob, class_name: "ActiveStorage::Blob"

  validates :expires_at, presence: true

  scope :expired, -> { where("expires_at <= ?", Time.current) }

  after_destroy_commit :purge_unattached_blob

  def expired?
    expires_at <= Time.current
  end

  def client_signed_id
    signed_id(purpose: SIGNED_ID_PURPOSE, expires_at: expires_at)
  end

  private

  def purge_unattached_blob
    blob.purge unless blob.attachments.exists?
  rescue => e
    Rails.logger.error("PendingImageUpload: failed to purge blob #{blob_id}: #{e.full_message}")
  end
end
