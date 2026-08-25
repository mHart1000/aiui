namespace :attachments do
  desc "Purge unattached image uploads older than 24 hours (set DRY_RUN=1 to inspect only)"
  task purge_expired: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    cutoff = ImageAttachmentProcessor::UPLOAD_TTL.ago
    scope = ActiveStorage::Blob.unattached.where(created_at: ..cutoff)
    puts "#{dry_run ? 'Would purge' : 'Purging'} #{scope.count} expired unattached image upload(s)"

    scope.find_each do |blob|
      puts "blob=#{blob.id} created=#{blob.created_at.iso8601} filename=#{blob.filename} bytes=#{blob.byte_size}"
      next if dry_run

      blob.with_lock do
        blob.purge if !blob.attachments.exists? && blob.created_at <= cutoff
      end
    end
  end
end
