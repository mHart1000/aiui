class AddThinkingToMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :messages, :thinking, :text
  end
end
