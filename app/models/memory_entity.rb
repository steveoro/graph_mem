# frozen_string_literal: true

class MemoryEntity < ApplicationRecord
  has_many :memory_observations, dependent: :destroy
  has_many :relations_from, class_name: "MemoryRelation", foreign_key: "to_entity_id", dependent: :destroy, inverse_of: :to_entity
  has_many :relations_to, class_name: "MemoryRelation", foreign_key: "from_entity_id", dependent: :destroy, inverse_of: :from_entity

  validates :name, presence: true, uniqueness: true
  validates :entity_type, presence: true

  after_initialize :set_default_counter_cache
  before_validation :canonicalize_entity_type
  after_commit :refresh_embedding, if: :embedding_fields_changed?

  EMBEDDING_FIELDS = %w[name entity_type aliases description].freeze

  private

  def set_default_counter_cache
    self.memory_observations_count ||= 0
  end

  def canonicalize_entity_type
    return if entity_type.blank?

    canonical = EntityTypeMapping.canonicalize(entity_type)
    self.entity_type = canonical if canonical.present?
  end

  def embedding_fields_changed?
    (previous_changes.keys & EMBEDDING_FIELDS).any?
  end

  def refresh_embedding
    EmbeddingService.embed_entity(self)
  rescue StandardError => e
    Rails.logger.warn "MemoryEntity#refresh_embedding failed for id=#{id}: #{e.message}"
  end
end
