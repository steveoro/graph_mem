# frozen_string_literal: true

module GraphTraversalSerializer
  module_function

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

  def path(result)
    {
      found: result.found,
      hop_count: result.hop_count,
      direction: result.direction,
      entities: entities_for(result.entity_ids),
      relations: relations_for(result.relation_ids)
    }
  end

  def entities_for(entity_ids)
    return [] if entity_ids.blank?

    by_id = MemoryEntity.where(id: entity_ids).includes(:memory_observations).index_by(&:id)
    entity_ids.filter_map { |id| by_id[id] }.map { |entity| entity_json(entity) }
  end

  def relations_for(relation_ids)
    return [] if relation_ids.blank?

    by_id = MemoryRelation.where(id: relation_ids).index_by(&:id)
    relation_ids.filter_map { |id| by_id[id] }.map { |relation| relation_json(relation) }
  end

  def entity_json(entity)
    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      observations: entity.memory_observations.map { |observation| observation_json(observation) },
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601
    }
  end

  def observation_json(observation)
    {
      observation_id: observation.id,
      content: observation.content,
      confidence: observation.confidence,
      source: observation.source,
      valid_from: observation.valid_from&.iso8601,
      valid_until: observation.valid_until&.iso8601,
      tags: observation.tags,
      created_at: observation.created_at.iso8601,
      updated_at: observation.updated_at.iso8601
    }
  end

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
