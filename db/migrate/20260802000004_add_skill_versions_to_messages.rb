class AddSkillVersionsToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :skill_versions, :jsonb
  end
end
