class AddRepoPathAndPiData < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :repo_path, :string
    add_column :messages, :pi_data, :json
  end
end
