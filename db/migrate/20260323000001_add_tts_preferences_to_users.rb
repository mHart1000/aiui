class AddTtsPreferencesToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :tts_enabled, :boolean, default: false, null: false
    add_column :users, :tts_voice, :string
    add_column :users, :tts_speed, :float, default: 1.0
  end
end
