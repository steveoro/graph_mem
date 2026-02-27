# frozen_string_literal: true

# Thread-local store for the current project context.
# For stdio transport, the process is long-lived so this persists across calls.
# For SSE/HTTP, the context is per-request unless stored externally.
class GraphMemContext
  class << self
    def current_project_id
      Thread.current[:graph_mem_project_id]
    end

    def current_project_id=(id)
      Thread.current[:graph_mem_project_id] = id
    end

    def clear!
      Thread.current[:graph_mem_project_id] = nil
    end

    def active?
      current_project_id.present?
    end

    # Returns entity IDs related to the current project (via part_of relations).
    # Useful for filtering search results.
    def scoped_entity_ids
      return nil unless active?

      ids = [ current_project_id ]
      ids += MemoryRelation
        .where(relation_type: "part_of", to_entity_id: current_project_id)
        .pluck(:from_entity_id)
      ids.uniq
    end
  end
end
