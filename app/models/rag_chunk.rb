class RagChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :rag_document
  belongs_to :user

  scope :with_embedding, -> { where.not(embedding: nil) }
end
