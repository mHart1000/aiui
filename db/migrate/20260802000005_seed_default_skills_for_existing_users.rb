class SeedDefaultSkillsForExistingUsers < ActiveRecord::Migration[8.1]
  # Migration-local classes so a later change to the Skill model can't alter
  # what this migration does on replay.
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationSkill < ActiveRecord::Base
    self.table_name = "skills"
  end

  def up
    now = Time.current

    MigrationUser.find_each do |user|
      rows = DEFAULT_SKILLS.map do |attrs|
        attrs.merge("user_id" => user.id, "created_at" => now, "updated_at" => now)
      end
      MigrationSkill.insert_all(rows, unique_by: [ :user_id, :name ])
    end
  end

  # Intentionally a no-op: by rollback time a seeded row is indistinguishable
  # from one the user has edited. CreateSkills drops the table anyway.
  def down
  end
end
