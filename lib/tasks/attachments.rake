namespace :attachments do
  desc "Purge expired pending image uploads (set DRY_RUN=1 to inspect only)"
  task purge_expired: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    scope = PendingImageUpload.expired
    puts "#{dry_run ? 'Would purge' : 'Purging'} #{scope.count} expired pending image upload(s)"

    scope.find_each do |pending|
      puts "pending_image_upload=#{pending.id} user=#{pending.user_id} blob=#{pending.blob_id} expired=#{pending.expires_at.iso8601}"
      pending.destroy! unless dry_run
    end
  end

  desc "List legacy unattached blobs whose owner cannot be reconstructed (never deletes)"
  task audit_legacy_unattached: :environment do
    scope = ActiveStorage::Blob
      .where.missing(:attachments)
      .where.not(id: PendingImageUpload.select(:blob_id))

    puts "Found #{scope.count} legacy unattached blob(s); no files were deleted"
    scope.find_each do |blob|
      puts "blob=#{blob.id} created=#{blob.created_at.iso8601} filename=#{blob.filename} bytes=#{blob.byte_size}"
    end
  end
end
