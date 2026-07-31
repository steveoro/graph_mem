# frozen_string_literal: true

# Resolves bounded part_of subtrees independently from an MCP client context.
class ProjectSubtree
  DEFAULT_MAX_ENTITIES = 1_000

  Result = Struct.new(:entity_ids, :truncated, :max_entities, keyword_init: true) do
    def complete?
      !truncated
    end

    def truncated?
      truncated
    end
  end

  class << self
    def resolve(project_id, max_entities: DEFAULT_MAX_ENTITIES)
      return Result.new(entity_ids: [], truncated: false, max_entities: max_entities) if project_id.blank?

      ids = [ project_id.to_i ]
      frontier = ids.dup
      truncated = false

      while frontier.any?
        children = MemoryRelation
          .where(relation_type: "part_of", to_entity_id: frontier)
          .order(:from_entity_id)
          .pluck(:from_entity_id)
        new_ids = children - ids
        break if new_ids.empty?

        remaining = max_entities - ids.size
        if new_ids.size > remaining
          ids.concat(new_ids.first(remaining))
          truncated = true
          break
        end

        ids.concat(new_ids)
        frontier = new_ids
      end

      Result.new(entity_ids: ids, truncated: truncated, max_entities: max_entities)
    end

    def ancestor_project_id(entity_id)
      current_id = entity_id.to_i
      visited = Set.new

      until current_id.blank? || current_id.zero? || visited.include?(current_id)
        visited.add(current_id)
        entity = MemoryEntity.find_by(id: current_id)
        return entity.id if entity&.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

        current_id = MemoryRelation
          .where(from_entity_id: current_id, relation_type: "part_of")
          .order(:to_entity_id)
          .pick(:to_entity_id)
      end

      nil
    end
  end
end
