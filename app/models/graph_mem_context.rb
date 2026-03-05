# frozen_string_literal: true

# Process-global store for the current project context.
#
# GraphMem is a single-user, single-process server. The context is shared
# across all Puma threads within the process via a Mutex-protected class
# variable, so set_context on one request is visible to search_entities
# on the next request regardless of which thread handles it.
#
# This replaces the earlier Thread.current implementation which silently
# lost context between SSE/HTTP requests served by different Puma threads.
class GraphMemContext
  @mutex = Mutex.new
  @project_id = nil

  class << self
    def current_project_id
      @mutex.synchronize { @project_id }
    end

    def current_project_id=(id)
      @mutex.synchronize { @project_id = id }
    end

    def clear!
      @mutex.synchronize { @project_id = nil }
    end

    def active?
      current_project_id.present?
    end

    # Returns entity IDs related to the current project (via part_of relations).
    # Used by search tools to boost in-context results.
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
