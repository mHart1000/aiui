class RemoveImageDataFromMessages < ActiveRecord::Migration[8.1]
  def up
    remove_column :messages, :image_data if column_exists?(:messages, :image_data)
  end

  def down
    add_column :messages, :image_data, :jsonb, default: [] unless column_exists?(:messages, :image_data)
  end
end
