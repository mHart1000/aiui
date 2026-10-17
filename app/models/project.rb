class Project < ApplicationRecord
  MAX_NAME_LENGTH = 100
  MAX_DESCRIPTION_LENGTH = 6_000

  belongs_to :user
  has_many :conversations, dependent: :nullify

  normalizes :name, with: ->(name) { name.strip }
  normalizes :description, with: ->(description) { description.to_s }, apply_to_nil: true
  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :description, length: { maximum: MAX_DESCRIPTION_LENGTH }
end
