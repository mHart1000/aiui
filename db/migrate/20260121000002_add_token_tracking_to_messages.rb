class AddTokenTrackingToMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :messages, :prompt_tokens, :integer
    add_column :messages, :completion_tokens, :integer
    add_column :messages, :total_tokens, :integer
  end
end
