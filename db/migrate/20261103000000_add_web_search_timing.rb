class AddWebSearchTiming < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :web_search_timing, :string, default: "low", null: false
    add_column :conversations, :web_search_timing, :string

    execute "UPDATE users SET web_search_timing = web_search_level"
    execute <<~SQL
      UPDATE conversations SET web_search_timing = web_search_level
      WHERE web_search_level IS NOT NULL
    SQL
  end

  def down
    remove_column :conversations, :web_search_timing
    remove_column :users, :web_search_timing
  end
end
