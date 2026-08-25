class User < ApplicationRecord
  DEFAULT_IMAGE_MAX_PIXELS = 6_000_000
  MIN_IMAGE_MAX_PIXELS = 2_073_600
  MAX_IMAGE_MAX_PIXELS = 25_000_000

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable,
         :registerable,
         :recoverable,
         :rememberable,
         :validatable,
         :jwt_authenticatable,
         jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  has_many :conversations, dependent: :destroy
  has_many :rag_documents, dependent: :destroy
  has_many :rag_chunks, dependent: :destroy
  has_many :skills, dependent: :destroy

  validates :image_max_pixels,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: MIN_IMAGE_MAX_PIXELS,
      less_than_or_equal_to: MAX_IMAGE_MAX_PIXELS
    }

  after_create :seed_default_skills

  private

  def seed_default_skills
    DEFAULT_SKILLS.each { |attrs| skills.create!(attrs) }
  end
end
