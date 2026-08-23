class CreateSkills < ActiveRecord::Migration[8.1]
  def change
    create_table :skills do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :description
      t.text :body, null: false
      t.boolean :enabled_by_default, default: false, null: false

      t.timestamps
    end

    add_index :skills, [ :user_id, :name ], unique: true
  end
end
