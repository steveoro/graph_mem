# frozen_string_literal: true

# What a project's facts say about a dependency-like entity it holds by `part_of` (Dream State
# R1b): deterministic, bounded, no LLM. A fact "names" the entity when it is held by the entity,
# when its keyword path (FactKeywords) holds the entity's name, or, while its path is pending, when
# its text names the entity (EntityTerms). The project's facts are those of its root and of its
# members (project_id).
#
#   DependencyEvidence.for_swap(library, project)
#   # => { entity_type: "Gem", facts: [{ observation_id: 12, entity_id: 3, entity_name: "SynthApp",
#   #      content: "SynthApp uses SynthLib for parsing." }] }
#   DependencyEvidence.facts_matching(library, project, ReviewPolicies::AutoApplyRelationRetype::OWNERSHIP_PATTERN)
#   # => [] (no ownership signal)
module DependencyEvidence
  # "uses it or used it": the use phrases a swap's evidence looks for.
  USE_PATTERN = /\b(?:uses?|used|using|depends? on|depended on|relies on|relied on|built (?:on|with)|requires?|required)\b/i
  # The most facts one row's evidence lists, the most candidate facts read, and the text kept of each.
  MAX_FACTS = 3
  SCAN_LIMIT = 200
  CONTENT_LIMIT = 200

  module_function

  # The evidence of a `swap` row: the entity's type and the project's facts that say it uses or
  # used the entity (at most MAX_FACTS, oldest first).
  # @param library [MemoryEntity] the dependency-like entity
  # @param project [MemoryEntity] the Project root it is part_of
  # @return [Hash] `{ entity_type:, facts: [{ observation_id:, entity_id:, entity_name:, content: }] }`
  def for_swap(library, project)
    facts = facts_matching(library, project, USE_PATTERN).first(MAX_FACTS)
    names = MemoryEntity.where(id: facts.map(&:memory_entity_id)).pluck(:id, :name).to_h
    { entity_type: library.entity_type,
      facts: facts.map do |fact|
        { observation_id: fact.id, entity_id: fact.memory_entity_id, entity_name: names[fact.memory_entity_id],
          content: fact.content.to_s.truncate(CONTENT_LIMIT) }
      end }
  end

  # The project's active facts that name the entity and whose text matches `pattern`, by id.
  # Reads at most SCAN_LIMIT candidates (those whose text holds the entity's name, whose keyword
  # path holds it, or held by the entity).
  # @param library [MemoryEntity]
  # @param project [MemoryEntity]
  # @param pattern [Regexp]
  # @return [Array<MemoryObservation>]
  def facts_matching(library, project, pattern)
    candidates(library, project).select { |fact| pattern.match?(fact.content.to_s) && names?(fact, library) }
  end

  # @return [Array<MemoryObservation>] the bounded candidate facts, oldest first
  def candidates(library, project)
    scope = MemoryObservation.active
    owners = scope.where(memory_entity_id: MemoryEntity.where(project_id: project.id).select(:id)).or(scope.where(memory_entity_id: project.id))
    owners.where("memory_observations.content LIKE :like OR JSON_CONTAINS(memory_observations.keywords, JSON_QUOTE(:name)) " \
                 "OR memory_observations.memory_entity_id = :id",
                 like: "%#{MemoryObservation.sanitize_sql_like(library.name)}%", name: library.name, id: library.id)
          .order(:id).limit(SCAN_LIMIT).to_a
  end

  # @param fact [MemoryObservation]
  # @param library [MemoryEntity]
  # @return [Boolean] the fact is about the entity: held by it, its keyword path holds its name, or
  #   (path pending) its text names it
  def names?(fact, library)
    return true if fact.memory_entity_id == library.id
    return Array(fact.keywords).any? { |name| name.to_s.casecmp?(library.name) } if fact.keywords_at

    EntityTerms.for(library).any? do |term|
      fact.content.to_s.match?(/(?:^|\W)#{term.split(/\s+/).map { |word| Regexp.escape(word) }.join('\\W+')}(?:$|\W)/i)
    end
  end
end
