class AddSkillPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :use_skills, :boolean, default: false, null: false
  end
end
