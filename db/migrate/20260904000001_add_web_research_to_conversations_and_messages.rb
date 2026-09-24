class AddWebResearchToConversationsAndMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :web_search_mode, :string, null: false, default: "off"
    add_column :messages, :web_search_data, :jsonb, null: false, default: {}
  end
end
