# frozen_string_literal: true

class SearchTool < ApplicationTool
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100
  PROJECTIONS = %w[observations relations].freeze

  def self.tool_name
    "search"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Search or page graph entities through one uniform response envelope. Omit `query` for catalog mode; " \
    "pass `query` alone for ranked summary mode; add `include` values observations and/or relations for subgraph mode. " \
    "Pass optional `page` (default 1), `per_page` (default 20, max 100), legacy alias `limit`, subgraph " \
    "`search_in_name`, `search_in_type`, `search_in_aliases`, `search_in_observations` flags, and `max_tokens` " \
    "(integer) to pack ranked results under an estimated token budget. Temporal recall: pass `occurred_after`, " \
    "`occurred_before`, and/or `as_of` (ISO 8601) to weight and filter facts by occurred time; temporal phrases in " \
    "the query itself (\"in October 2026\", \"during 2024\", \"last week\") are also understood. " \
    "Active context boosts query matches rather than filtering them. " \
    "Do not use to load known entity IDs; use `get_entities` instead. " \
    "Do not use for multi-hop expansion; use `traverse_graph` instead. " \
    "Do not use for synthesized prose; use `summarize` instead."

  arguments do
    optional(:query).maybe(:string).description("Search query. Omit for catalog mode.")
    optional(:include).array(:string).description("Subgraph projections: observations and/or relations.")
    optional(:search_in_name).filled(:bool)
    optional(:search_in_type).filled(:bool)
    optional(:search_in_aliases).filled(:bool)
    optional(:search_in_observations).filled(:bool)
    optional(:page).filled(:integer).description("Page number. Defaults to 1.")
    optional(:per_page).filled(:integer).description("Results per page (1-100). Defaults to 20.")
    optional(:limit).filled(:integer).description("Legacy alias for per_page; per_page wins when both are supplied.")
    optional(:occurred_after).maybe(:string).description("ISO 8601 lower bound for occurred-time recall (valid_from/valid_until, or retention time for undated facts).")
    optional(:occurred_before).maybe(:string).description("ISO 8601 upper bound for occurred-time recall.")
    optional(:as_of).maybe(:string).description("ISO 8601 instant: facts whose validity contains it (or already retained by it) — cannot be combined with occurred_after/occurred_before.")
    optional(:max_tokens).filled(:integer).description("Estimated token budget (chars/4 heuristic): ranked results are packed until the next item would exceed it.")
  end

  def call(query: nil, include: [], page: nil, per_page: nil, limit: nil,
           search_in_name: true, search_in_type: true, search_in_aliases: true,
           search_in_observations: true, occurred_after: nil, occurred_before: nil,
           as_of: nil, max_tokens: nil)
    effective_page, effective_per_page = normalized_paging(page, per_page || limit)
    projections = normalize_projections(include)
    temporal_window = build_temporal_window(occurred_after, occurred_before, as_of)
    max_tokens = TokenBudget.validate_max_tokens!(max_tokens, error_class: FastMcp::Tool::InvalidArgumentsError)

    if query.nil?
      if projections.any? || temporal_window.present? || max_tokens.present?
        raise FastMcp::Tool::InvalidArgumentsError, "include, temporal bounds and max_tokens require a query."
      end

      return { mode: "catalog" }.merge(
        EntityCatalogService.call(page: effective_page, per_page: effective_per_page)
      )
    end
    raise FastMcp::Tool::InvalidArgumentsError, "Query term cannot be blank." if query.blank?

    if projections.any?
      subgraph_result(
        query,
        projections,
        page: effective_page,
        per_page: effective_per_page,
        search_in_name: search_in_name,
        search_in_type: search_in_type,
        search_in_aliases: search_in_aliases,
        search_in_observations: search_in_observations,
        temporal_window: temporal_window,
        max_tokens: max_tokens
      )
    else
      summary_result(
        query,
        page: effective_page,
        per_page: effective_per_page,
        temporal_window: temporal_window,
        max_tokens: max_tokens
      )
    end
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "SearchTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def normalized_paging(page, per_page)
    normalized_page = page.nil? ? DEFAULT_PAGE : page.to_i
    normalized_per_page = per_page.nil? ? DEFAULT_PER_PAGE : per_page.to_i
    raise FastMcp::Tool::InvalidArgumentsError, "Page number must be 1 or greater." if normalized_page < 1
    unless normalized_per_page.between?(1, MAX_PER_PAGE)
      raise FastMcp::Tool::InvalidArgumentsError,
            "Per page count must be between 1 and #{MAX_PER_PAGE}."
    end

    [ normalized_page, normalized_per_page ]
  end

  def normalize_projections(projections)
    normalized = Array(projections).map(&:to_s).uniq
    unknown = normalized - PROJECTIONS
    if unknown.any?
      raise FastMcp::Tool::InvalidArgumentsError,
            "include values must be observations and/or relations; received #{unknown.join(', ')}."
    end

    normalized
  end

  def summary_result(query, page:, per_page:, temporal_window: nil, max_tokens: nil)
    context_scope = graph_mem_context.scoped_entity_scope
    offset = (page - 1) * per_page
    payload = EntityRetrievalService.search(
      query,
      limit: offset + per_page,
      semantic: true,
      # The ambient context is a ranking boost only — passing it as
      # scope_entity_ids would hard-filter temporal-only queries.
      context_entity_ids: context_scope&.entity_ids,
      context_scope: context_scope,
      temporal_window: temporal_window
    )
    page_results = payload[:results].map(&:to_h).drop(offset).first(per_page)
    retrieval = payload[:retrieval].merge(result_count: page_results.size)

    results = page_results
    if max_tokens.present?
      # The budget applies per page: the page is sliced first, then packed,
      # so page N's budget is never spent on pages 1..N-1. The item-less
      # response envelope is counted once; cut items are reported via
      # token_budget.dropped_on_page and never reappear on later pages.
      # Diagnostics and a next_move slot are seeded BEFORE the envelope is
      # estimated — fields written after the fit would push the real
      # response over the budget.
      retrieval[:token_budget] = TokenBudget.diagnostics_placeholder(
        max_tokens: max_tokens, dropped_on_page: true
      )
      # The hint text is seeded at full length so a truncated page never
      # pushes the final response over budget; removed when nothing dropped.
      retrieval[:next_move] = "lower per_page or raise max_tokens to see the dropped ranks"
      # The reserve covers the fields ToolSuccessResponse appends after
      # the tool returns (version, next_move, and the context block only
      # when no context is active) — all part of the delivered
      # structuredContent, so they must be inside the counted envelope.
      envelope = {
        mode: "summary",
        results: [],
        pagination: { per_page: per_page, current_page: page },
        retrieval: retrieval
      }.merge(TokenBudget.wrapper_reserve(context_active: context_scope.present?))
      budget_fit = TokenBudget.fit_with_envelope(page_results, envelope: envelope, max_tokens: max_tokens)
      results = budget_fit.items
      retrieval[:result_count] = results.size
      retrieval[:token_budget] = TokenBudget.diagnostics(
        max_tokens: max_tokens, estimated_tokens: budget_fit.estimated_tokens,
        truncated: budget_fit.truncated,
        envelope_tokens: budget_fit.envelope_tokens,
        items_before: budget_fit.items_before, items_after: budget_fit.items_after,
        dropped_on_page: budget_fit.dropped_count
      )
      if budget_fit.truncated
        retrieval[:next_move] = "lower per_page or raise max_tokens to see the dropped ranks"
      else
        retrieval.delete(:next_move)
      end
    end

    {
      mode: "summary",
      results: results,
      pagination: { per_page: per_page, current_page: page },
      retrieval: retrieval
    }
  end

  def subgraph_result(query, projections, **options)
    payload = SubgraphSearchService.call(
      query: query,
      context_scope: graph_mem_context.scoped_entity_scope,
      logger: logger,
      include_observations: projections.include?("observations"),
      include_relations: projections.include?("relations"),
      **options
    )

    { mode: "subgraph" }.merge(payload)
  end

  def build_temporal_window(occurred_after, occurred_before, as_of)
    TemporalWindow.from_params(
      occurred_after: occurred_after,
      occurred_before: occurred_before,
      as_of: as_of
    )
  rescue ArgumentError => e
    raise FastMcp::Tool::InvalidArgumentsError, e.message
  end
end
