# frozen_string_literal: true

class MemoryRelation < ApplicationRecord
  include Auditable

  belongs_to :from_entity, class_name: "MemoryEntity", foreign_key: "from_entity_id"
  belongs_to :to_entity, class_name: "MemoryEntity", foreign_key: "to_entity_id"

  serialize :properties, coder: JSON

  after_commit :recompute_observation_trust_scores, on: [ :create, :destroy ]

  before_validation :canonicalize_relation_type

  # When true, the save keeps `relation_type` exactly as assigned (no canonicalization): an undo
  # re-inserting a deleted relation restores its stored type as it was, and RelationTypeSweep's
  # merge updates a twin's weight/confidence/properties without touching its type.
  # @return [Boolean, nil]
  attr_accessor :keep_stored_type

  validates :relation_type, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :properties_are_an_object
  validate :relation_semantics_are_valid, on: :create

  # Folds a relation type to the spelling stored for it: trimmed, lower-cased, and every run of
  # whitespace and/or hyphens turned into one underscore ("Has Many", "has-many", " HAS  many "
  # all become `has_many`). Any other character is kept as it is; no transliteration.
  #
  # @param raw_type [String, Symbol, nil]
  # @return [String] the folded type ("" for nil)
  def self.fold_relation_type(raw_type)
    raw_type.to_s.strip.downcase.gsub(/[\s-]+/, "_")
  end

  # The canonical type a raw type maps to, or nil when nothing maps. The folded spelling is looked
  # up first, then the original one lower-cased, so a variant stored with spaces or hyphens (an
  # operator's table row) resolves as well as the underscore spelling.
  #
  # @param raw_type [String, Symbol, nil]
  # @return [String, nil]
  def self.mapped_relation_type(raw_type)
    return nil if raw_type.blank?

    folded = fold_relation_type(raw_type)
    RelationTypeMapping.canonicalize(folded) || RelationTypeMapping.canonicalize(raw_type.to_s.strip.downcase)
  end

  # The one place a relation type is normalized, on every write and lookup path: the canonical
  # type when it maps (table row, else the code vocabulary), else the folded type (novel types stay
  # allowed, stored in lower snake case). A blank type is returned as it came, so the presence
  # validation still catches it.
  #
  # @param raw_type [String, Symbol, nil] e.g. "Has Many", "has-many", "calls_method", "novel type"
  # @return [String, Symbol, nil] e.g. "has_many", "calls", "novel_type"
  def self.canonical_relation_type(raw_type)
    return raw_type if raw_type.blank?

    mapped_relation_type(raw_type) || fold_relation_type(raw_type)
  end

  # While true, the after_commit trust-score recompute is skipped (bulk
  # imports create too many relations for a recompute per edge); the caller
  # recomputes once per touched entity afterwards.
  def self.suppress_trust_recompute
    previous = Thread.current[:gmem_trust_recompute_suppressed]
    Thread.current[:gmem_trust_recompute_suppressed] = true
    yield
  ensure
    Thread.current[:gmem_trust_recompute_suppressed] = previous
  end

  def self.trust_recompute_suppressed?
    Thread.current[:gmem_trust_recompute_suppressed] == true
  end

  # Recomputes the trust score of every active observation of the given entities (the structural
  # boost counts their relations). The after_commit hook runs it per created or deleted edge; bulk
  # writers that suppress the hook call it once per touched entity.
  #
  # @param entity_ids [Enumerable<Integer>]
  # @return [void]
  def self.recompute_trust_scores_for(entity_ids)
    entity_ids.to_a.compact.uniq.each do |entity_id|
      MemoryObservation
        .where(memory_entity_id: entity_id, status: MemoryObservation::ACTIVE_STATUS)
        .find_each do |observation|
          observation.update_column(:trust_score, ObservationTrustRanker.rank(observation))
        end
    end
  end

  private

  def canonicalize_relation_type
    return if relation_type.blank? || keep_stored_type

    self.relation_type = MemoryRelation.canonical_relation_type(relation_type)
  end

  def properties_are_an_object
    return if properties.is_a?(Hash)

    errors.add(:properties, "must be an object")
  end

  def relation_semantics_are_valid
    RelationSemantics.validate_create!(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: relation_type
    )
  rescue RelationSemantics::ValidationError => e
    errors.add(:base, e.message)
  end

  def recompute_observation_trust_scores
    return if self.class.trust_recompute_suppressed?

    self.class.recompute_trust_scores_for([ from_entity_id, to_entity_id ])
  end
end
