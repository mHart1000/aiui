class AddPdfSourcesToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :pdf_sources, :jsonb, null: false, default: []
  end
end
