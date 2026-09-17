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
    "Pass optional `page` (default 1), `per_page` (default 20, max 100), legacy alias `limit`, and subgraph " \
    "`search_in_name`, `search_in_type`, `search_in_aliases`, `search_in_observations` flags. " \
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
  end

  def call(query: nil, include: [], page: nil, per_page: nil, limit: nil,
           search_in_name: true, search_in_type: true, search_in_aliases: true,
           search_in_observations: true)
    effective_page, effective_per_page = normalized_paging(page, per_page || limit)
    projections = normalize_projections(include)

    if query.nil?
      raise FastMcp::Tool::InvalidArgumentsError, "include requires a query." if projections.any?

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
        search_in_observations: search_in_observations
      )
    else
      summary_result(query, page: effective_page, per_page: effective_per_page)
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

  def summary_result(query, page:, per_page:)
    context_scope = graph_mem_context.scoped_entity_scope
    offset = (page - 1) * per_page
    payload = EntityRetrievalService.search(
      query,
      limit: offset + per_page,
      semantic: true,
      context_entity_ids: context_scope&.entity_ids,
      scope_entity_ids: context_scope&.entity_ids,
      context_scope: context_scope
    )
    results = payload[:results].drop(offset).first(per_page).map(&:to_h)
    retrieval = payload[:retrieval].merge(result_count: results.size)

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
end
