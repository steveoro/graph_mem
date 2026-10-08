# frozen_string_literal: true

# Shared entity search used by MCP and REST so ranking and context behavior match.
class EntityRetrievalService
  class << self
    def search(query, limit: 50, semantic: true, context_entity_ids: nil, scope_entity_ids: nil,
               context_scope: nil, temporal_window: nil)
      window = temporal_window || TemporalQueryParser.extract(query)&.window
      strategy = HybridSearchStrategy.new
      context_scope ||= GraphMemContext.scoped_entity_scope if scope_entity_ids.blank? && context_entity_ids.blank?
      scoped_ids = scope_entity_ids || context_entity_ids || context_scope&.entity_ids
      results = strategy.search(
        query,
        limit: limit,
        semantic: semantic,
        context_entity_ids: scoped_ids,
        temporal_window: window
      )

      {
        results: results,
        retrieval: {
          scope_entity_count: scoped_ids&.size,
          scope_truncated: context_scope&.truncated == true,
          scope_max_entities: context_scope&.max_entities,
          result_count: results.size,
          semantic: semantic
        }.merge(window.present? ? { temporal: window.to_h } : {})
      }
    end
  end
end
