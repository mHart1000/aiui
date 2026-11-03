class AddWebSearchDatesToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :web_search_start_date, :date
    add_column :conversations, :web_search_end_date, :date
  end
end
