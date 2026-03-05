# frozen_string_literal: true

class MemoryObservation < ApplicationRecord
  include Auditable

  belongs_to :memory_entity, counter_cache: true

  validates :content, presence: true

  after_create :set_initial_embedding
  after_commit :refresh_embedding, on: [ :update ], if: :content_previously_changed?

  def as_json(options = {})
    super(options.merge(except: Array(options[:except]) | [ :embedding ]))
  end

  private

  def set_initial_embedding
    EmbeddingService.embed_observation(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryObservation#set_initial_embedding failed: #{e.message}"
  end

  def refresh_embedding
    EmbeddingService.embed_observation(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryObservation#refresh_embedding failed for id=#{id}: #{e.message}"
  end
end
