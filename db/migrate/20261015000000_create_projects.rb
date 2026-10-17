class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description, null: false, default: ""
      t.timestamps
    end
    add_reference :conversations, :project, foreign_key: { on_delete: :nullify }
  end
end
