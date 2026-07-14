# frozen_string_literal: true

class MemoryObservation < ApplicationRecord
  include Auditable

  EMBEDDING_FIELDS = %w[content source tags].freeze

  belongs_to :memory_entity, counter_cache: true

  serialize :tags, coder: JSON

  validates :content, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :validity_range_is_ordered
  validate :tags_are_strings

  after_create :set_initial_embedding
  after_commit :refresh_embedding, on: [ :update ], if: :embedding_fields_changed?

  def as_json(options = {})
    super(options.merge(except: Array(options[:except]) | [ :embedding ]))
  end

  private

  def embedding_fields_changed?
    (previous_changes.keys & EMBEDDING_FIELDS).any?
  end

  def validity_range_is_ordered
    return if valid_from.blank? || valid_until.blank? || valid_until >= valid_from

    errors.add(:valid_until, "must be on or after valid_from")
  end

  def tags_are_strings
    return if tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) }

    errors.add(:tags, "must be an array of strings")
  end

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
