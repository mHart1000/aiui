class AddPersonaVersionToMessages < ActiveRecord::Migration[7.2]
  def change
    add_column :messages, :persona_version, :string
  end
end
