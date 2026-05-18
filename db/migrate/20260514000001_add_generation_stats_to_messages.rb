class AddGenerationStatsToMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :messages, :generation_ms, :integer
    add_column :messages, :tokens_per_second, :float
  end
end
