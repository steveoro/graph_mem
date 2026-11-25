# frozen_string_literal: true

class MemoryRelation < ApplicationRecord
  include Auditable

  belongs_to :from_entity, class_name: "MemoryEntity", foreign_key: "from_entity_id"
  belongs_to :to_entity, class_name: "MemoryEntity", foreign_key: "to_entity_id"

  serialize :properties, coder: JSON

  after_commit :recompute_observation_trust_scores, on: [ :create, :destroy ]

  # Only when the type is being set: a create, or an update that changes it. An update of other
  # columns (an entity merge re-pointing an endpoint, its undo) keeps the stored spelling, so it
  # never turns a variant into `part_of` behind the single-parent/cycle checks and the membership sync.
  before_validation :canonicalize_relation_type, if: -> { new_record? || will_save_change_to_relation_type? }

  # When true, a save keeps `relation_type` exactly as assigned (no canonicalization): an undo
  # re-inserting a deleted relation or writing back an updated type (ChangeSetUndo::AuditInverse,
  # ChangeSetUndo::Merge) restores its stored type as it was, and the next RelationTypeSweep
  # canonicalizes it.
  # @return [Boolean, nil]
  attr_accessor :keep_stored_type

  validates :relation_type, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :properties_are_an_object
  validate :relation_semantics_are_valid, on: :create

  # Folds a relation type to the spelling stored for it: trimmed, lower-cased, and every run of
  # whitespace, hyphens and underscores that holds at least one whitespace or hyphen turned into
  # one underscore ("Has Many", "has-many", " HAS  many ", "has_ many", "part_-of" all become
  # `has_many` / `part_of`). A run of underscores alone ("synth__type") is kept as typed, so a
  # stored snake-case type never changes. Any other character is kept as it is; no transliteration.
  #
  # @param raw_type [String, Symbol, nil]
  # @return [String] the folded type ("" for nil)
  def self.fold_relation_type(raw_type)
    raw_type.to_s.strip.downcase.gsub(/[\s_-]*[\s-][\s_-]*/, "_")
  end

  # Whether a stored type is `part_of` as SQL reads it: compared under the column's collation
  # (utf8mb4_general_ci: case and trailing spaces don't count), the way ProjectMembership,
  # RelationSemantics and the unique key see it. "Part_Of" is; "Part Of" and "child_of" aren't.
  #
  # @param stored_type [String, nil]
  # @return [Boolean]
  def self.reads_as_part_of?(stored_type)
    return false if stored_type.blank?

    type = stored_type.to_s
    # ASCII: the collation's rule in Ruby (case-insensitive, trailing spaces padded); else ask the DB.
    return type.sub(/ +\z/, "").casecmp?("part_of") if type.ascii_only?

    sql = sanitize_sql_array([ "SELECT CONVERT(? USING utf8mb4) COLLATE utf8mb4_general_ci = 'part_of'", type ])
    connection.select_value(sql).to_i == 1
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
  # boost counts their relations): ObservationTrustRecompute. The after_commit hook runs it per
  # created or deleted edge; bulk writers that suppress the hook call it once per touched entity.
  #
  # @param entity_ids [Enumerable<Integer>]
  # @return [void]
  def self.recompute_trust_scores_for(entity_ids)
    ObservationTrustRecompute.call(entity_ids: entity_ids)
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
    # A restored row keeps its stored type: a variant SQL doesn't read as part_of (e.g. "Is Part Of")
    # is not a parent edge, so the hierarchy rules RelationSemantics would apply to its canonical
    # type don't hold it (it existed next to the child's real parent).
    return if keep_stored_type && !MemoryRelation.reads_as_part_of?(relation_type)

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
