class SeedDefaultSkillsForExistingUsers < ActiveRecord::Migration[8.1]
  # Migration-local so later Skill model changes can't alter this on replay.
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

  # No-op: a seeded row is indistinguishable from an edited one by rollback time.
  def down
  end
end
