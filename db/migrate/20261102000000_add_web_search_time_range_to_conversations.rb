class AddWebSearchTimeRangeToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :web_search_time_range, :string
  end
end
