require "digest"

class Skill < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :body, presence: true

  # Matches Persona's versioning so messages.skill_versions reads like persona_version.
  def version
    Digest::SHA1.hexdigest(body)[0, 8]
  end
end
