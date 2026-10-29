# frozen_string_literal: true

# What the entity panel shows (UI-3 P4, editable for the operator since UI-4b): the entity, its
# project, its observations by trust (paged; never an embedding call), its relations both ways,
# grouped by type, and its recent change sets.
#
#   panel = EntityPanel.new(entity, include_obsolete: false, page: 1)
#   panel.observations       # => first 10 active observations, highest trust first
#   panel.relations[:outgoing] # => { "depends_on" => [<MemoryRelation>, ...] } (20 per type at most)
#   panel.recent_changes     # => the last 5 change sets anchored on the entity
class EntityPanel
  OBSERVATIONS_PER_PAGE = 10
  RELATIONS_PER_TYPE = 20
  # Relations loaded per direction before grouping; the counts still cover them all.
  RELATIONS_LOAD_LIMIT = 500
  RECENT_CHANGES = 5

  attr_reader :entity, :include_obsolete

  # @param entity [MemoryEntity]
  # @param include_obsolete [Boolean] also obsolete and superseded observations
  # @param page [Integer, String] observation page, 1-based; anything else is 1, and past the end
  #   it is the last page (so a huge page never becomes a huge OFFSET)
  def initialize(entity, include_obsolete: false, page: 1)
    @entity = entity
    @include_obsolete = include_obsolete
    @requested_page = [ page.to_s.match?(/\A\d+\z/) ? page.to_i : 1, 1 ].max
  end

  # @return [Integer] the page shown, between 1 and the last page
  def page
    @page ||= [ @requested_page, last_page ].min
  end

  # @return [Array<ChangeSet>] the newest change sets anchored on this entity
  def recent_changes
    @recent_changes ||= ChangeSet.where(subject_type: "MemoryEntity", subject_id: entity.id)
                                 .order(created_at: :desc, id: :desc).limit(RECENT_CHANGES).to_a
  end

  # @return [String, nil] the Project root's name for a member
  def project_name
    entity.project&.name
  end

  # @return [Array<MemoryObservation>] this page, by trust (then confidence, then oldest first)
  def observations
    @observations ||= observation_scope.order(trust_score: :desc, confidence: :desc, id: :asc)
                                       .offset((page - 1) * OBSERVATIONS_PER_PAGE).limit(OBSERVATIONS_PER_PAGE + 1).to_a
    @observations.first(OBSERVATIONS_PER_PAGE)
  end

  # @return [Boolean] whether another observation page follows
  def more_observations?
    observations
    @observations.size > OBSERVATIONS_PER_PAGE
  end

  # @return [Integer] obsolete and superseded observations (for the "Show obsolete" toggle)
  def inactive_observation_count
    @inactive_observation_count ||= entity.memory_observations.inactive.count
  end

  # @return [Hash{Symbol => Hash{String => Array<MemoryRelation>}}] :outgoing and :incoming
  def relations
    @relations ||= {
      outgoing: grouped(MemoryRelation.where(from_entity_id: entity.id).includes(:to_entity)),
      incoming: grouped(MemoryRelation.where(to_entity_id: entity.id).includes(:from_entity))
    }
  end

  # @return [Hash{Symbol => Hash{String => Integer}}] relation counts per direction and type
  def relation_counts
    @relation_counts ||= {
      outgoing: MemoryRelation.where(from_entity_id: entity.id).group(:relation_type).count,
      incoming: MemoryRelation.where(to_entity_id: entity.id).group(:relation_type).count
    }
  end

  private

  def last_page
    return @requested_page if @requested_page == 1

    [ (observation_scope.count + OBSERVATIONS_PER_PAGE - 1) / OBSERVATIONS_PER_PAGE, 1 ].max
  end

  def observation_scope
    include_obsolete ? entity.memory_observations : entity.memory_observations.active
  end

  def grouped(scope)
    scope.order(:relation_type, :id).limit(RELATIONS_LOAD_LIMIT).group_by(&:relation_type)
         .transform_values { |list| list.first(RELATIONS_PER_TYPE) }
  end
end
