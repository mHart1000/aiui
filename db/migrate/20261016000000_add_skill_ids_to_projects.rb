class AddSkillIdsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :skill_ids, :jsonb, null: false, default: []
  end
end
