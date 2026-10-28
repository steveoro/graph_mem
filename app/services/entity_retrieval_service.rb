# frozen_string_literal: true

# Shared entity search used by MCP and REST so ranking and context behavior match.
class EntityRetrievalService
  class << self
    # @param ambient_context [Boolean] false skips the fallback to the "default" client bucket's
    #   context when none is passed (the Search page ignores agents' context)
    # @param text [Boolean] false skips the text channel (the Search page's Semantic mode)
    # @param filter [SearchFilter, nil] project/type/field filter applied inside every channel;
    #   reported as `retrieval.filters` when it narrows anything
    # @return [Hash] `{ results: Array<HybridSearchStrategy::SearchResult>, retrieval: Hash }`
    def search(query, limit: 50, semantic: true, context_entity_ids: nil, scope_entity_ids: nil,
               context_scope: nil, temporal_window: nil, perspective: nil, ambient_context: true, text: true,
               filter: nil)
      extraction = TemporalQueryParser.apply(query, temporal_window: temporal_window)
      window = extraction.window
      strategy = HybridSearchStrategy.new
      if ambient_context && scope_entity_ids.blank? && context_entity_ids.blank?
        context_scope ||= GraphMemContext.scoped_entity_scope
      end
      scoped_ids = scope_entity_ids || context_entity_ids || context_scope&.entity_ids
      # Context ids (argument or ambient GraphMemContext) go to the strategy as
      # the boost channel; only an explicitly-requested scope_entity_ids may
      # hard-filter the temporal paths — see HybridSearchStrategy.
      boost_ids = context_entity_ids || context_scope&.entity_ids
      results = strategy.search(
        extraction.effective_query,
        limit: limit,
        semantic: semantic,
        context_entity_ids: boost_ids,
        scope_entity_ids: scope_entity_ids,
        temporal_window: window,
        temporal_only: extraction.temporal_only?,
        perspective: perspective,
        text: text,
        filter: filter
      )

      # A windowed query whose residual terms match nothing falls back to a
      # pure temporal listing instead of returning an empty result set.
      fallback = false
      if window.present? && !extraction.temporal_only? && results.empty?
        results = strategy.search(
          "",
          limit: limit,
          semantic: semantic,
          context_entity_ids: boost_ids,
          scope_entity_ids: scope_entity_ids,
          temporal_window: window,
          temporal_only: true,
          perspective: perspective,
          text: text,
          filter: filter
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
         .merge(filter&.diagnostic ? { filters: filter.diagnostic } : {})
      }
    end
  end
end
