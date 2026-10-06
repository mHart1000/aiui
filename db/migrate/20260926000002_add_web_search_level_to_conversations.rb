class AddWebSearchLevelToConversations < ActiveRecord::Migration[8.1]
  # Adds the level override and makes the mode override nullable so that null
  # means "inherit from the user", mirroring the use_skills override columns.
  def up
    add_column :conversations, :web_search_level, :string, null: true
    change_column_default :conversations, :web_search_mode, nil
    change_column_null :conversations, :web_search_mode, true
  end

  def down
    execute("UPDATE conversations SET web_search_mode = 'off' WHERE web_search_mode IS NULL")
    change_column_null :conversations, :web_search_mode, false
    change_column_default :conversations, :web_search_mode, "off"
    remove_column :conversations, :web_search_level
  end
end
