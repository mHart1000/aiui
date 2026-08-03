class AddSkillOverridesToConversations < ActiveRecord::Migration[8.1]
  # Both nullable: null means inherit from the user, so an explicitly empty
  # skill_ids array can still mean "no skills in this conversation".
  def change
    add_column :conversations, :use_skills, :boolean
    add_column :conversations, :skill_ids, :jsonb
  end
end
