# frozen_string_literal: true

class MemoryObservation < ApplicationRecord
  belongs_to :memory_entity, counter_cache: true

  validates :content, presence: true

  after_commit :refresh_embedding, on: [ :create, :update ], if: :content_previously_changed?

  private

  def refresh_embedding
    EmbeddingService.embed_observation(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryObservation#refresh_embedding failed for id=#{id}: #{e.message}"
  end
end
