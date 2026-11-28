class AddPiModelToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :pi_model, :string
  end
end
