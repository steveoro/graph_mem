# frozen_string_literal: true

class GraphSearch
  # Ranked summary mode: one page of EntityRetrievalService results, optionally packed under a
  # token budget. Asks the ranking for `offset + per_page` results and slices, so page N of a
  # search is the same whichever caller asks.
  #
  #   GraphSearch::Summary.call("SynthWidget", page: 1, per_page: 20, context_scope: nil)
  class Summary
    NEXT_MOVE = "lower per_page or raise max_tokens to see the dropped ranks"

    # @param query [String]
    # @param page [Integer] validated, >= 1
    # @param per_page [Integer] validated, 1-100
    # @param context_scope [ProjectSubtree::Result, nil] boost only
    # @param temporal_window [TemporalWindow, nil]
    # @param max_tokens [Integer, nil] validated budget
    # @param perspective [String, nil]
    # @return [Hash] `{ mode: "summary", results:, pagination:, retrieval: }`
    def self.call(query, page:, per_page:, context_scope:, temporal_window: nil, max_tokens: nil, perspective: nil)
      offset = (page - 1) * per_page
      payload = EntityRetrievalService.search(
        query,
        limit: offset + per_page,
        semantic: true,
        # The ambient context is a ranking boost only — passing it as
        # scope_entity_ids would hard-filter temporal-only queries.
        context_entity_ids: context_scope&.entity_ids,
        context_scope: context_scope,
        temporal_window: temporal_window,
        perspective: perspective
      )
      page_results = payload[:results].map(&:to_h).drop(offset).first(per_page)
      retrieval = payload[:retrieval].merge(result_count: page_results.size)
      pagination = { per_page: per_page, current_page: page }

      results = page_results
      if max_tokens.present?
        results = pack(page_results, retrieval, pagination: pagination, max_tokens: max_tokens,
                                                context_active: context_scope.present?)
      end

      { mode: "summary", results: results, pagination: pagination, retrieval: retrieval }
    end

    # The budget applies per page: the page is sliced first, then packed,
    # so page N's budget is never spent on pages 1..N-1. The item-less
    # response envelope is counted once; cut items are reported via
    # token_budget.dropped_on_page and never reappear on later pages.
    # Diagnostics and a next_move slot are seeded BEFORE the envelope is
    # estimated — fields written after the fit would push the real
    # response over the budget.
    def self.pack(page_results, retrieval, pagination:, max_tokens:, context_active:)
      retrieval[:token_budget] = TokenBudget.diagnostics_placeholder(max_tokens: max_tokens, dropped_on_page: true)
      # The hint text is seeded at full length so a truncated page never
      # pushes the final response over budget; removed when nothing dropped.
      retrieval[:next_move] = NEXT_MOVE
      # The reserve covers the fields ToolSuccessResponse appends after
      # the tool returns (version, next_move, and the context block only
      # when no context is active) — all part of the delivered
      # structuredContent, so they must be inside the counted envelope.
      envelope = { mode: "summary", results: [], pagination: pagination, retrieval: retrieval }
                 .merge(TokenBudget.wrapper_reserve(context_active: context_active))
      budget_fit = TokenBudget.fit_with_envelope(page_results, envelope: envelope, max_tokens: max_tokens)
      retrieval[:result_count] = budget_fit.items.size
      retrieval[:token_budget] = TokenBudget.diagnostics(
        max_tokens: max_tokens, estimated_tokens: budget_fit.estimated_tokens,
        truncated: budget_fit.truncated,
        envelope_tokens: budget_fit.envelope_tokens,
        items_before: budget_fit.items_before, items_after: budget_fit.items_after,
        dropped_on_page: budget_fit.dropped_count
      )
      retrieval.delete(:next_move) unless budget_fit.truncated
      budget_fit.items
    end
    private_class_method :pack
  end
end
