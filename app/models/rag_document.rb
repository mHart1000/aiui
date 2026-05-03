class RagDocument < ApplicationRecord
  STATUSES = %w[pending processing ready failed].freeze
  SOURCE_TYPES = %w[personalization memory web_cache].freeze
  FILE_FORMATS = %w[pdf txt md docx json].freeze

  belongs_to :user
  has_many :rag_chunks, dependent: :destroy

  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :file_format, inclusion: { in: FILE_FORMATS }, allow_nil: true

  scope :personalization, -> { where(source_type: "personalization") }
  scope :ready, -> { where(status: "ready") }

  STATUSES.each do |s|
    define_method("status_#{s}?") { status == s }
  end
end
