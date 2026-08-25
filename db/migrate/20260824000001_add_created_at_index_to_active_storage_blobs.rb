class AddCreatedAtIndexToActiveStorageBlobs < ActiveRecord::Migration[8.1]
  def change
    add_index :active_storage_blobs, :created_at
  end
end
