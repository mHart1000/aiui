namespace :attachments do
  desc "Purge expired pending image uploads (set DRY_RUN=1 to inspect only)"
  task purge_expired: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    scope = PendingImageUpload.expired.order(:id)
    puts "#{dry_run ? 'Would purge' : 'Purging'} #{scope.count} expired pending image upload(s)"

    scope.find_each do |pending|
      puts "pending_image_upload=#{pending.id} user=#{pending.user_id} blob=#{pending.blob_id} expired=#{pending.expires_at.iso8601}"
      pending.destroy! unless dry_run
    end
  end
end
