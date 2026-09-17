# frozen_string_literal: true

class EntitiesFetchService
  RELATION_MODES = %w[all internal].freeze

  def self.call(**args)
    new(**args).call
  end

  def initialize(entity_ids:, relations: nil, include_obsolete: false, include_ranked: false,
                 query: nil, observation_limit: nil, strict_single: true,
                 always_rank_observations: false)
    @entity_ids = Array(entity_ids).map(&:to_i).uniq
    @relations_mode = relations.presence || default_relations_mode
    @include_obsolete = include_obsolete
    @include_ranked = include_ranked
    @query = query
    @observation_limit = observation_limit
    @strict_single = strict_single
    @always_rank_observations = always_rank_observations
  end

  def call
    validate!

    entities_by_id = MemoryEntity
                     .where(id: @entity_ids)
                     .includes(:memory_observations, :active_memory_observations)
                     .index_by(&:id)
    missing_ids = @entity_ids - entities_by_id.keys
    if @strict_single && @entity_ids.one? && missing_ids.any?
      raise ActiveRecord::RecordNotFound, "Entity with ID=#{@entity_ids.first} not found."
    end

    {
      entities: @entity_ids.filter_map { |id| entities_by_id[id] }.map { |entity| entity_payload(entity) },
      relations: relation_payloads,
      missing_entity_ids: missing_ids,
      relation_scope: @relations_mode
    }
  end

  private

  def validate!
    if @entity_ids.empty?
      raise FastMcp::Tool::InvalidArgumentsError, "entity_ids array cannot be empty."
    end
    return if @relations_mode.in?(RELATION_MODES)

    raise FastMcp::Tool::InvalidArgumentsError,
          "relations must be one of: #{RELATION_MODES.join(', ')}."
  end

  def default_relations_mode
    @entity_ids.one? ? "all" : "internal"
  end

  def entity_payload(entity)
    pool = @include_obsolete ? entity.memory_observations : entity.active_memory_observations
    observations = ranked_observations(pool)

    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      observations_truncated: @observation_limit.present? && observations.size < pool.size,
      observations: observations.map { |observation| MemoryObservationSerializer.call(observation) }
    }
  end

  def ranked_observations(observations)
    if @query.present?
      ObservationRankingService.rank(observations, query: @query, limit: @observation_limit)
    elsif @include_ranked || @always_rank_observations || @observation_limit.present?
      ObservationRankingService.rank(observations, mode: "trust", limit: @observation_limit)
    else
      observations
    end
  end

  def relation_payloads
    scope =
      if @relations_mode == "internal"
        MemoryRelation.where(from_entity_id: @entity_ids, to_entity_id: @entity_ids)
      else
        MemoryRelation.where(from_entity_id: @entity_ids)
                      .or(MemoryRelation.where(to_entity_id: @entity_ids))
      end

    scope.distinct.order(:id).map { |relation| GraphTraversalSerializer.relation_json(relation) }
  end
end
