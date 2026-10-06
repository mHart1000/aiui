class AddWebSearchDefaultsToUsers < ActiveRecord::Migration[8.1]
  # User-level defaults; a conversation whose override is null inherits these.
  def change
    add_column :users, :web_search_mode, :string, null: false, default: "off"
    add_column :users, :web_search_level, :string, null: false, default: "low"
  end
end
