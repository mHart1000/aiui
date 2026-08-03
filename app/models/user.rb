class User < ApplicationRecord
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

  after_create :seed_default_skills

  private

  def seed_default_skills
    DEFAULT_SKILLS.each { |attrs| skills.create!(attrs) }
  end
end
