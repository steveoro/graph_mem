# frozen_string_literal: true

class SearchTool < ApplicationTool
  DEFAULT_PAGE = GraphSearch::DEFAULT_PAGE
  DEFAULT_PER_PAGE = GraphSearch::DEFAULT_PER_PAGE
  MAX_PER_PAGE = GraphSearch::MAX_PER_PAGE

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

  description "Recall what earlier sessions learned before you act. Call before choosing a convention " \
    "(version bump, changelog, docs or test style, config location, release step) and before first editing a " \
    "file or component named in the task; query by the task's project, file paths and component names, not " \
    "only by topic. " \
    "Search or page graph entities through one uniform response envelope. Omit `query` for catalog mode; " \
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
    optional(:perspective).maybe(:string).description("Observation perspective hard filter: 'world' surfaces only factual observations, 'experience' only work-log entries; omitted returns both.")
    optional(:max_tokens).filled(:integer).description("Estimated token budget (chars/4 heuristic): ranked results are packed until the next item would exceed it.")
  end

  def call(query: nil, include: [], page: nil, per_page: nil, limit: nil,
           search_in_name: true, search_in_type: true, search_in_aliases: true,
           search_in_observations: true, occurred_after: nil, occurred_before: nil,
           as_of: nil, max_tokens: nil, perspective: nil)
    GraphSearch.call(
      query: query, include: include, page: page, per_page: per_page, limit: limit,
      search_in_name: search_in_name, search_in_type: search_in_type, search_in_aliases: search_in_aliases,
      search_in_observations: search_in_observations, occurred_after: occurred_after,
      occurred_before: occurred_before, as_of: as_of, max_tokens: max_tokens, perspective: perspective,
      context_scope: graph_mem_context.scoped_entity_scope, logger: logger
    )
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, GraphMem::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "SearchTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
