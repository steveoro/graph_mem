# frozen_string_literal: true

# Shared entity search used by MCP and REST so ranking and context behavior match.
class EntityRetrievalService
  class << self
    def search(query, limit: 50, semantic: true, context_entity_ids: nil, scope_entity_ids: nil)
      strategy = HybridSearchStrategy.new
      scoped_ids = scope_entity_ids || context_entity_ids || GraphMemContext.scoped_entity_ids
      results = strategy.search(
        query,
        limit: limit,
        semantic: semantic,
        context_entity_ids: scoped_ids
      )

      {
        results: results,
        retrieval: {
          scope_entity_count: scoped_ids&.size,
          result_count: results.size,
          semantic: semantic
        }
      }
    end
  end
end
