# frozen_string_literal: true

class MemoryObservation < ApplicationRecord
  include Auditable

  EMBEDDING_FIELDS = %w[content source tags].freeze
  ACTIVE_STATUS = "active"
  OBSOLETE_STATUS = "obsolete"
  SUPERSEDED_STATUS = "superseded"
  STATUSES = [ ACTIVE_STATUS, OBSOLETE_STATUS, SUPERSEDED_STATUS ].freeze
  MUTABLE_FIELDS = %i[content confidence source valid_from valid_until tags].freeze

  class InactiveObservationError < StandardError; end

  belongs_to :memory_entity, counter_cache: true
  belongs_to :superseded_by,
             class_name: "MemoryObservation",
             optional: true,
             inverse_of: :superseded_observations
  has_many :superseded_observations,
           class_name: "MemoryObservation",
           foreign_key: :superseded_by_id,
           dependent: :nullify,
           inverse_of: :superseded_by

  serialize :tags, coder: JSON

  scope :active, -> { where(status: ACTIVE_STATUS) }
  scope :inactive, -> { where.not(status: ACTIVE_STATUS) }

  validates :content, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validate :validity_range_is_ordered
  validate :tags_are_strings
  validate :lifecycle_state_is_consistent

  after_create :set_initial_embedding
  after_commit :refresh_embedding, on: [ :update ], if: :embedding_fields_changed?

  def as_json(options = {})
    super(options.merge(except: Array(options[:except]) | [ :embedding ]))
  end

  def active?
    status == ACTIVE_STATUS
  end

  def obsolete?
    status == OBSOLETE_STATUS
  end

  def superseded?
    status == SUPERSEDED_STATUS
  end

  def mark_obsolete!(reason: nil)
    return self unless active?

    update!(
      status: OBSOLETE_STATUS,
      obsoleted_at: Time.current,
      obsolescence_reason: reason.presence,
      superseded_by: nil
    )
    self
  end

  def update_active!(attributes)
    raise InactiveObservationError, "Inactive observations cannot be updated." unless active?

    update!(attributes.slice(*MUTABLE_FIELDS))
    self
  end

  def supersede!(attributes, reason: nil)
    replacement = nil

    self.class.transaction do
      lock!
      raise InactiveObservationError, "Inactive observations cannot be superseded." unless active?

      replacement = self.class.create!(replacement_attributes.merge(attributes.slice(*MUTABLE_FIELDS)))
      update!(
        status: SUPERSEDED_STATUS,
        obsoleted_at: Time.current,
        obsolescence_reason: reason.presence,
        superseded_by: replacement
      )
    end

    replacement
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

  def lifecycle_state_is_consistent
    if active?
      errors.add(:obsoleted_at, "must be blank for active observations") if obsoleted_at.present?
      errors.add(:superseded_by, "must be blank for active observations") if superseded_by.present?
    elsif obsoleted_at.blank?
      errors.add(:obsoleted_at, "must be present for inactive observations")
    end

    if superseded? && superseded_by.blank?
      errors.add(:superseded_by, "must be present for superseded observations")
    elsif !superseded? && superseded_by.present?
      errors.add(:superseded_by, "is only valid for superseded observations")
    end

    return if superseded_by.blank?

    errors.add(:superseded_by, "cannot reference itself") if superseded_by.equal?(self) || superseded_by_id == id
    if superseded_by.memory_entity_id != memory_entity_id
      errors.add(:superseded_by, "must belong to the same entity")
    end
  end

  def replacement_attributes
    {
      memory_entity: memory_entity,
      content: content,
      confidence: confidence,
      source: source,
      valid_from: valid_from,
      valid_until: valid_until,
      tags: tags.dup
    }
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
