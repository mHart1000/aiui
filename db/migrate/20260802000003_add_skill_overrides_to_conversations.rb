class AddSkillOverridesToConversations < ActiveRecord::Migration[8.1]
  # Nullable so null can mean inherit and [] can mean no skills here.
  def change
    add_column :conversations, :use_skills, :boolean
    add_column :conversations, :skill_ids, :jsonb
  end
end
