# frozen_string_literal: true

# Fact pertinence (1.77.0): each fact's keyword path, deterministic (no LLM). The path is the
# project root's name, the name of the entity that holds the fact, then each other project entity
# the fact mentions, in the order the text first names it (FactKeywords::TermIndex), so two facts
# on one entity can be told apart by what they are about:
#
#   "It belongs to a User."  on GogglesDb::AdminGrant
#   # => ["goggles_db", "GogglesDb::AdminGrant", "GogglesDb::User"]
#
# The path is stored in memory_observations.keywords (never embedded) and stamped in keywords_at
# (NULL = pending). FactKeywordsJob computes pending facts after writes and nightly; a project scan
# computes its own new facts before its reconcile commits.
#
#   FactKeywords.compute!(MemoryObservation.active.keywords_pending.limit(500)) # => 500
module FactKeywords
  module_function

  # Computes and stores the keyword path of each fact, one TermIndex per project.
  #
  # @param observations [Enumerable<MemoryObservation>]
  # @param now [Time] the stamp
  # @return [Integer] the facts stamped
  def compute!(observations, now: Time.current)
    facts = observations.to_a
    projects = {}
    indexes = {}
    facts.each do |fact|
      owner = fact.memory_entity
      # Stamped even without an entity, so a batch never fetches it again.
      next fact.update_columns(keywords: [], keywords_at: now) unless owner

      project = projects.fetch(owner.id) { projects[owner.id] = project_of(owner) }
      index = indexes.fetch(project&.id) { indexes[project&.id] = TermIndex.new(project) }
      fact.update_columns(keywords: index.path_for(fact.content, owner: owner).path, keywords_at: now)
    end
    facts.size
  end

  # @param path [Array<String>] a keyword path
  # @param owner_name [String, nil] the name of the entity that holds the fact
  # @return [Array<String>] the names after the owner: the entities the fact mentions ([] when the
  #   path doesn't hold the owner, e.g. still pending)
  def mentions(path, owner_name)
    path = Array(path)
    index = owner_name && path.index(owner_name)
    index ? path.drop(index + 1) : []
  end

  # Computes the paths still pending among `observations`, when the feature is on, and returns them
  # all (the ones it computed updated in place). For a background generator that must compare paths
  # now rather than wait for FactKeywordsJob.
  #
  # @param observations [Array<MemoryObservation>] with their entities loaded
  # @return [Array<MemoryObservation>]
  def ensure!(observations)
    list = Array(observations)
    pending = list.select { |observation| observation.keywords_at.nil? }
    compute!(pending) if pending.any? && AppSettings.fact_keywords_enabled?
    list
  end

  # @param project [String, nil] a Project root's name (the rake tasks' PROJECT); nil for every fact
  # @return [ActiveRecord::Relation] active facts, of that project's root and members when named
  # @raise [ArgumentError] for a name no Project root has
  def active_facts(project: nil)
    scope = MemoryObservation.active
    return scope unless (name = project.to_s.strip.presence)

    root = MemoryEntity.find_by(name: name, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
    raise ArgumentError, "no Project root named #{name.inspect}" unless root

    scope.where(memory_entity_id: MemoryEntity.where(project_id: root.id).select(:id)).or(scope.where(memory_entity_id: root.id))
  end

  # @param entity [MemoryEntity]
  # @return [MemoryEntity, nil] the entity's project root (itself for a root)
  def project_of(entity)
    return entity if entity.project_root?

    project_id = entity.project_id || ProjectSubtree.ancestor_project_id(entity.id)
    MemoryEntity.find_by(id: project_id) if project_id
  end
end
