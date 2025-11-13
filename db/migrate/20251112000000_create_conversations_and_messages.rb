class CreateConversationsAndMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :conversations do |t|
      t.string :title
      t.timestamps
    end

    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.timestamps
    end
  end
end
