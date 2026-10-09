# frozen_string_literal: true

# Shared entity search used by MCP and REST so ranking and context behavior match.
class EntityRetrievalService
  class << self
    def search(query, limit: 50, semantic: true, context_entity_ids: nil, scope_entity_ids: nil,
               context_scope: nil, temporal_window: nil)
      extraction = TemporalQueryParser.apply(query, temporal_window: temporal_window)
      window = extraction.window
      strategy = HybridSearchStrategy.new
      context_scope ||= GraphMemContext.scoped_entity_scope if scope_entity_ids.blank? && context_entity_ids.blank?
      scoped_ids = scope_entity_ids || context_entity_ids || context_scope&.entity_ids
      results = strategy.search(
        extraction.effective_query,
        limit: limit,
        semantic: semantic,
        context_entity_ids: scoped_ids,
        temporal_window: window,
        temporal_only: extraction.temporal_only?
      )

      # A windowed query whose residual terms match nothing falls back to a
      # pure temporal listing instead of returning an empty result set.
      fallback = false
      if window.present? && !extraction.temporal_only? && results.empty?
        results = strategy.search(
          "",
          limit: limit,
          semantic: semantic,
          context_entity_ids: scoped_ids,
          temporal_window: window,
          temporal_only: true
        )
        fallback = true
      end

      temporal_diagnostic = window.present? ? extraction.diagnostic.merge(fallback: (fallback ? "temporal_only" : nil)).compact : nil

      {
        results: results,
        retrieval: {
          scope_entity_count: scoped_ids&.size,
          scope_truncated: context_scope&.truncated == true,
          scope_max_entities: context_scope&.max_entities,
          result_count: results.size,
          semantic: semantic
        }.merge(temporal_diagnostic.present? ? { temporal: temporal_diagnostic } : {})
      }
    end
  end
end
