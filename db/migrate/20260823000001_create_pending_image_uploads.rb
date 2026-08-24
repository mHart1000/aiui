class CreatePendingImageUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_image_uploads do |t|
      t.references :user, null: false, foreign_key: true
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }, index: { unique: true }
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :pending_image_uploads, :expires_at
    add_index :pending_image_uploads, [ :user_id, :expires_at ]
  end
end
