class AddFooterMetadataToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :model_label, :string
    add_column :messages, :persona_label, :string
  end
end
