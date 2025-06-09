# frozen_string_literal: true

# MemoryGraph Resource implementation to provide a combined view of entities, observations, and relations
class MemoryGraphResource < ApplicationResource
  # Templated URI with all supported query parameters
  uri "memory_graph{?entity_id,depth,include_observations,include_relations}"
  resource_name "MemoryGraph"
  description "Provides a graph view of memory entities with their related observations and relations"
  mime_type "application/json"

  def content
    # Get the starting entity ID
    entity_id = params[:entity_id].to_i
    return JSON.generate({ error: "Missing required parameter: entity_id" }) unless entity_id.positive?

    # Find the starting entity
    entity = MemoryEntity.find_by(id: entity_id)
    return JSON.generate({ error: "Entity not found with ID: #{entity_id}" }) unless entity

    # Set the traversal depth (default to 1)
    depth = (params[:depth] || 1).to_i
    depth = 1 if depth <= 0
    depth = 3 if depth > 3 # Cap at 3 for performance

    # Check inclusion parameters
    include_observations = params[:include_observations] == "true"
    include_relations = params[:include_relations] == "true"

    # Build the graph with the specified depth
    graph = build_graph(entity, depth, include_observations, include_relations)

    # Return the result
    JSON.generate(graph)
  end

  private

  # Recursively build a graph representation starting from an entity
  def build_graph(entity, depth, include_observations, include_relations, visited_ids = Set.new)
    return nil if entity.nil? || visited_ids.include?(entity.id)

    # Mark this entity as visited
    visited_ids.add(entity.id)

    # Start with the entity data
    result = entity.as_json

    # Add observations if requested
    if include_observations && entity.memory_observations_count.to_i.positive?
      result["observations"] = entity.memory_observations.as_json
    end

    # Stop recursion if we've reached the max depth
    return result if depth <= 0 || !include_relations

    # Find outgoing and incoming relations
    outgoing_relations = MemoryRelation.where(from_entity_id: entity.id)
    incoming_relations = MemoryRelation.where(to_entity_id: entity.id)

    # Process outgoing relations
    result["outgoing_relations"] = outgoing_relations.map do |relation|
      relation_data = relation.as_json

      # Recursively include the target entity if depth allows
      if depth > 0
        to_entity = MemoryEntity.find_by(id: relation.to_entity_id)
        if to_entity && !visited_ids.include?(to_entity.id)
          relation_data["to_entity"] = build_graph(
            to_entity,
            depth - 1,
            include_observations,
            include_relations,
            visited_ids.clone
          )
        end
      end

      relation_data
    end

    # Process incoming relations
    result["incoming_relations"] = incoming_relations.map do |relation|
      relation_data = relation.as_json

      # Recursively include the source entity if depth allows
      if depth > 0
        from_entity = MemoryEntity.find_by(id: relation.from_entity_id)
        if from_entity && !visited_ids.include?(from_entity.id)
          relation_data["from_entity"] = build_graph(
            from_entity,
            depth - 1,
            include_observations,
            include_relations,
            visited_ids.clone
          )
        end
      end

      relation_data
    end

    result
  end
end
