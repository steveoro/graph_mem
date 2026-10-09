# frozen_string_literal: true

class MemoryEntity < ApplicationRecord
  include Auditable

  has_many :memory_observations, dependent: :destroy
  has_many :active_memory_observations,
           -> { active },
           class_name: "MemoryObservation",
           inverse_of: :memory_entity
  has_many :relations_from, class_name: "MemoryRelation", foreign_key: "from_entity_id", dependent: :destroy, inverse_of: :from_entity
  has_many :relations_to, class_name: "MemoryRelation", foreign_key: "to_entity_id", dependent: :destroy, inverse_of: :to_entity

  validates :name, presence: true, uniqueness: true
  validates :entity_type, presence: true

  after_initialize :set_default_counter_cache
  before_validation :canonicalize_entity_type
  after_create :set_initial_embedding
  after_commit :refresh_embedding, on: [ :update ], if: :embedding_fields_changed?

  EMBEDDING_FIELDS = %w[name entity_type aliases description].freeze

  # `with_embedding`/`missing_embedding` track the `embedded_at` stamp
  # EmbeddingService#store_vector sets when a real vector is written —
  # NOT the vector itself (the BEFORE INSERT trigger fills placeholder
  # zero-vectors on this NOT NULL column).
  scope :with_embedding, -> { where.not(embedded_at: nil) }
  scope :missing_embedding, -> { where(embedded_at: nil) }

  def as_json(options = {})
    super(options.merge(except: Array(options[:except]) | [ :embedding ]))
  end

  private

  def set_default_counter_cache
    self.memory_observations_count ||= 0
  end

  def canonicalize_entity_type
    return if entity_type.blank?

    canonical = EntityTypeMapping.canonicalize(entity_type)
    self.entity_type = canonical if canonical.present?
  end

  def set_initial_embedding
    return if EmbeddingService.inline_embeddings_suppressed?

    EmbeddingService.embed_entity(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryEntity#set_initial_embedding failed: #{e.message}"
  end

  def embedding_fields_changed?
    (previous_changes.keys & EMBEDDING_FIELDS).any?
  end

  def refresh_embedding
    # Suppressed (bulk imports): the stored vector is stale now — mark it
    # missing so the deferred backfill re-embeds this row.
    if EmbeddingService.inline_embeddings_suppressed?
      update_column(:embedded_at, nil) if embedded_at.present?
      return
    end

    EmbeddingService.embed_entity(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryEntity#refresh_embedding failed for id=#{id}: #{e.message}"
  end
end
