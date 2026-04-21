class AddScaffoldingPreferenceToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :use_scaffolding, :boolean, default: true, null: false
  end
end
