# frozen_string_literal: true

class MemoryGraphResource < ApplicationResource
  uri "memory_graph{?entity_id,depth,include_observations,include_relations}"
  resource_name "MemoryGraph"
  description "Provides a graph view of memory entities with their related observations and relations"
  mime_type "application/json"

  def content
    entity_id = params[:entity_id].to_i
    return JSON.generate({ error: "Missing required parameter: entity_id" }) unless entity_id.positive?

    entity = MemoryEntity.find_by(id: entity_id)
    return JSON.generate({ error: "Entity not found with ID: #{entity_id}" }) unless entity

    depth = (params[:depth] || 1).to_i
    depth = 1 if depth <= 0
    depth = 3 if depth > 3

    include_observations = params[:include_observations] == "true"
    include_relations = params[:include_relations] == "true"

    graph = if include_relations
      traversal = GraphTraversalService.new.expand(
        start_entity_id: entity.id,
        max_depth: depth,
        direction: "both",
        max_entities: GraphTraversalService::MAX_ENTITIES
      )
      build_graph(entity.id, depth, include_observations, traversal)
    else
      entity_result(entity, include_observations)
    end

    JSON.generate(graph)
  end

  private

  def build_graph(entity_id, depth, include_observations, traversal, visited_ids = Set.new)
    return nil if visited_ids.include?(entity_id)

    entities = traversal_entities(traversal)
    relations = traversal_relations(traversal)
    entity = entities[entity_id]
    return nil unless entity

    visited_ids.add(entity_id)
    result = entity_result(entity, include_observations)
    return result if depth <= 0

    result["outgoing_relations"] = relations.select { |relation| relation.from_entity_id == entity_id }.map do |relation|
      relation_data = relation.as_json

      unless visited_ids.include?(relation.to_entity_id)
        relation_data["to_entity"] = build_graph(
          relation.to_entity_id,
          depth - 1,
          include_observations,
          traversal,
          visited_ids.clone
        )
      end

      relation_data
    end

    result["incoming_relations"] = relations.select { |relation| relation.to_entity_id == entity_id }.map do |relation|
      relation_data = relation.as_json

      unless visited_ids.include?(relation.from_entity_id)
        relation_data["from_entity"] = build_graph(
          relation.from_entity_id,
          depth - 1,
          include_observations,
          traversal,
          visited_ids.clone
        )
      end

      relation_data
    end

    result
  end

  def traversal_entities(traversal)
    @traversal_entities ||= MemoryEntity.where(id: traversal.entity_ids)
      .includes(:memory_observations)
      .index_by(&:id)
  end

  def traversal_relations(traversal)
    @traversal_relations ||= MemoryRelation.where(id: traversal.relation_ids).order(:id).to_a
  end

  def entity_result(entity, include_observations)
    result = entity.as_json
    if include_observations && entity.memory_observations_count.to_i.positive?
      result["observations"] = entity.memory_observations.as_json
    end
    result
  end
end
