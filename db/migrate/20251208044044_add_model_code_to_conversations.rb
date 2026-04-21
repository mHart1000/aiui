class AddModelCodeToConversations < ActiveRecord::Migration[7.2]
  def change
    add_column :conversations, :model_code, :string
  end
end
