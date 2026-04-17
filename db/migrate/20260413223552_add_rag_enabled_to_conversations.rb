class AddRagEnabledToConversations < ActiveRecord::Migration[7.2]
  def change
    add_column :conversations, :rag_enabled, :boolean, default: false, null: false
  end
end
