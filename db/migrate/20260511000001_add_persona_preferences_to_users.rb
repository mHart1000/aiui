class AddPersonaPreferencesToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :use_persona, :boolean, default: true, null: false
    add_column :users, :persona_id, :string, default: "persona1", null: false
  end
end
