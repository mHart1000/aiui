class RenameHighWebSearchLevelToMedium < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET web_search_level = 'medium' WHERE web_search_level = 'high'"
    execute "UPDATE conversations SET web_search_level = 'medium' WHERE web_search_level = 'high'"
  end

  def down
    execute "UPDATE users SET web_search_level = 'high' WHERE web_search_level = 'medium'"
    execute "UPDATE conversations SET web_search_level = 'high' WHERE web_search_level = 'medium'"
  end
end
