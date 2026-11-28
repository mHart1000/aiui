class AddPiModeToProjects < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :pi_mode, :boolean, default: false, null: false
    execute <<~SQL.squish
      UPDATE projects
      SET pi_mode = TRUE
      WHERE repo_path IS NOT NULL AND BTRIM(repo_path) <> ''
    SQL
  end

  def down
    remove_column :projects, :pi_mode
  end
end
