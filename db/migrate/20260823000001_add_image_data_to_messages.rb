class AddImageDataToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :image_data, :jsonb, default: []
  end
end
