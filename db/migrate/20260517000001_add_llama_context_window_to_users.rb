class AddLlamaContextWindowToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :llama_context_window, :integer, default: 8192
  end
end
