# frozen_string_literal: true

module GraphTraversalSerializer
  module_function

  # Serializes a breadth-first traversal result.
  #
  # @param result [GraphTraversalService::TraversalResult]
  # @return [Hash] entities, relations, and traversal metadata
  def traversal(result)
    {
      entities: entities_for(result.entity_ids),
      relations: relations_for(result.relation_ids),
      traversal: {
        start_entity_id: result.start_entity_id,
        max_depth: result.max_depth,
        direction: result.direction,
        visited_depth: result.visited_depth,
        truncated: result.truncated
      }
    }
  end

  # Serializes a shortest-path result.
  #
  # @param result [GraphTraversalService::PathResult]
  # @return [Hash] path status, hop count, direction, entities, and relations
  def path(result)
    {
      found: result.found,
      hop_count: result.hop_count,
      direction: result.direction,
      entities: entities_for(result.entity_ids),
      relations: relations_for(result.relation_ids)
    }
  end

  # Loads and serializes entities in the supplied ID order.
  #
  # @param entity_ids [Array<Integer>] ordered entity IDs
  # @param query [String, nil] optional observation relevance query
  # @param observation_limit [Integer, nil] maximum observations per entity
  # @return [Array<Hash>] serialized entities; unknown IDs are omitted
  def entities_for(entity_ids, query: nil, observation_limit: nil)
    return [] if entity_ids.blank?

    by_id = MemoryEntity.where(id: entity_ids).includes(:active_memory_observations).index_by(&:id)
    entity_ids.filter_map { |id| by_id[id] }.map { |entity| entity_json(entity, query: query, observation_limit: observation_limit) }
  end

  # Loads and serializes relations in the supplied ID order.
  #
  # @param relation_ids [Array<Integer>] ordered relation IDs
  # @return [Array<Hash>] serialized relations; unknown IDs are omitted
  def relations_for(relation_ids)
    return [] if relation_ids.blank?

    by_id = MemoryRelation.where(id: relation_ids).index_by(&:id)
    relation_ids.filter_map { |id| by_id[id] }.map { |relation| relation_json(relation) }
  end

  # Serializes one entity and its active, ranked observations.
  #
  # @param entity [MemoryEntity]
  # @param query [String, nil] optional observation relevance query
  # @param observation_limit [Integer, nil] maximum observations to return
  # @return [Hash] entity attributes and serialized observations
  def entity_json(entity, query: nil, observation_limit: nil)
    observations = ObservationRankingService.rank(
      entity.active_memory_observations,
      query: query,
      limit: observation_limit
    )
    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      observations: observations.map { |observation| observation_json(observation) },
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601
    }
  end

  # Serializes one observation using the shared MCP representation.
  #
  # @param observation [MemoryObservation]
  # @return [Hash] observation lifecycle, provenance, and content fields
  def observation_json(observation)
    MemoryObservationSerializer.call(observation)
  end

  # Serializes one directed graph relation.
  #
  # @param relation [MemoryRelation]
  # @return [Hash] endpoint IDs, type, metadata, and timestamps
  def relation_json(relation)
    {
      relation_id: relation.id,
      from_entity_id: relation.from_entity_id,
      to_entity_id: relation.to_entity_id,
      relation_type: relation.relation_type,
      weight: relation.weight,
      confidence: relation.confidence,
      properties: relation.properties,
      created_at: relation.created_at.iso8601,
      updated_at: relation.updated_at.iso8601
    }
  end
end
