# frozen_string_literal: true

# Removal-style evidence (Dream State R1c): a project's fact saying that an entity the Project still
# depends_on, or still holds by a direct part_of, was removed, replaced or dropped. Deterministic,
# bounded, no LLM.
#
# - The edges: a Project root's outgoing `depends_on`, and a `part_of` into a Project root from an
#   entity of a dependency-like type (DependencyLikeTypes: a library not swapped yet). An ordinary
#   member's part_of is not read: its own facts say "removed" or "dropped" about other things (a
#   change note), and R1's aim is an outdated library. A blank setting reads no part_of edge.
# - The facts: the active facts of the project, those held by its root or by a member (project_id),
#   that name the entity (held by it, its keyword path holds its name, or its text names it,
#   EntityTerms) and match REMOVAL_PATTERN. A global library's own facts are not the project's.
#
#   RemovalEvidence.edges(after_id: 0, limit: 200, types: DependencyLikeTypes.current)
#   # => [#<MemoryRelation SynthApp depends_on SynthLib>, ...]
#   RemovalEvidence.facts(relation)                # => [#<MemoryObservation "SynthApp replaced SynthLib with SynthParser.">]
module RemovalEvidence
  # The removal phrases (a constant list, shown in docs/dream_state.md), matched case-insensitively
  # as whole words; "…" stands for up to three words ("replaced SynthLib with SynthParser").
  PHRASES = [
    "removed", "replaced … by", "replaced … with", "dropped", "no longer uses", "no longer used", "no longer depends on",
    "no longer needs", "migrated away from", "migrated off", "switched away from", "got rid of", "ripped out", "uninstalled"
  ].freeze
  # The words "…" may stand for, as a regex fragment.
  GAP = "(?:\\s+\\S+){0,3}\\s+"

  # @param phrase [String] one of PHRASES
  # @return [String] its regex source: the words joined by whitespace, "…" by GAP
  def self.phrase_source(phrase)
    phrase.split(" … ").map { |part| part.split.map { |word| Regexp.escape(word) }.join("\\s+") }.join(GAP)
  end

  REMOVAL_PATTERN = /\b(?:#{PHRASES.map { |phrase| phrase_source(phrase) }.join('|')})\b/i
  PART_OF = "part_of"
  DEPENDS_ON = "depends_on"
  # The most candidate facts read per edge (by id), and the text kept in a row's excerpt.
  SCAN_LIMIT = 200
  EXCERPT_LIMIT = 200

  module_function

  # The candidate edges after `after_id`, by id: a Project root's depends_on, or a part_of into one
  # from a dependency-like entity.
  # @param after_id [Integer] the cursor (a relation id)
  # @param limit [Integer]
  # @param types [DependencyLikeTypes] the setting, read once by the caller
  # @return [Array<MemoryRelation>] with both ends loaded
  def edges(after_id:, limit:, types: DependencyLikeTypes.current)
    roots = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil).select(:id)
    scope = MemoryRelation.where(relation_type: DEPENDS_ON, from_entity_id: roots)
    if types.stored_types.any?
      libraries = MemoryEntity.where(entity_type: types.stored_types).select(:id)
      scope = scope.or(MemoryRelation.where(relation_type: PART_OF, to_entity_id: roots, from_entity_id: libraries))
    end
    scope.where("memory_relations.id > ?", after_id).includes(:from_entity, :to_entity).order(:id).limit(limit).to_a
  end

  # @param relation [MemoryRelation] an edge from .edges
  # @return [Array(MemoryEntity, MemoryEntity)] the Project and the entity it depends_on or holds
  def ends(relation)
    relation.relation_type == PART_OF ? [ relation.to_entity, relation.from_entity ] : [ relation.from_entity, relation.to_entity ]
  end

  # The project's active facts that name the edge's entity with a removal phrase, oldest first.
  # @param relation [MemoryRelation]
  # @return [Array<MemoryObservation>]
  def facts(relation)
    project, entity = ends(relation)
    return [] unless project && entity

    candidates(project, entity).select { |fact| REMOVAL_PATTERN.match?(fact.content.to_s) && names?(fact, entity) }
  end

  # @return [Array<MemoryObservation>] at most SCAN_LIMIT facts of the project whose text or keyword
  #   path holds the entity's name, or held by the entity, by id
  def candidates(project, entity)
    owners = MemoryObservation.active.where(memory_entity_id: MemoryEntity.where(project_id: project.id).select(:id))
                              .or(MemoryObservation.active.where(memory_entity_id: project.id))
    owners.where("memory_observations.content LIKE :like OR JSON_CONTAINS(memory_observations.keywords, JSON_QUOTE(:name)) " \
                 "OR memory_observations.memory_entity_id = :id",
                 like: "%#{MemoryObservation.sanitize_sql_like(entity.name)}%", name: entity.name, id: entity.id)
          .order(:id).limit(SCAN_LIMIT).to_a
  end

  # @param fact [MemoryObservation]
  # @param entity [MemoryEntity]
  # @return [Boolean] held by the entity, its keyword path holds the name, or its text names it. The
  #   text counts even with a computed path: a global library is in no project's path.
  def names?(fact, entity)
    return true if fact.memory_entity_id == entity.id
    return true if Array(fact.keywords).any? { |name| name.to_s.casecmp?(entity.name) }

    EntityTerms.for(entity).any? do |term|
      fact.content.to_s.match?(/(?:^|\W)#{term.split(/\s+/).map { |word| Regexp.escape(word) }.join('\\W+')}(?:$|\W)/i)
    end
  end

  # @param fact [MemoryObservation]
  # @return [String] the fact's text, cut to EXCERPT_LIMIT
  def excerpt(fact) = fact.content.to_s.squish.truncate(EXCERPT_LIMIT)
end
