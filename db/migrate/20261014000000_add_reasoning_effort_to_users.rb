class AddReasoningEffortToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :reasoning_effort, :string, default: "high", null: false
  end
end
