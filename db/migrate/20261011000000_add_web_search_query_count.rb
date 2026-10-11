class AddWebSearchQueryCount < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :web_search_query_count, :integer, default: 2, null: false
    add_column :conversations, :web_search_query_count, :integer

    execute <<~SQL
      UPDATE users SET web_search_query_count =
        CASE web_search_level WHEN 'high' THEN 4 WHEN 'medium' THEN 3 ELSE 2 END
    SQL
    execute <<~SQL
      UPDATE conversations SET web_search_query_count =
        CASE web_search_level WHEN 'high' THEN 4 WHEN 'medium' THEN 3 ELSE 2 END
      WHERE web_search_level IS NOT NULL
    SQL
  end

  def down
    remove_column :conversations, :web_search_query_count
    remove_column :users, :web_search_query_count
  end
end
