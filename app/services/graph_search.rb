# frozen_string_literal: true

# The `search` tool's logic, shared by the MCP tool and the operator Search page so both get the
# same results for the same arguments. Catalog mode (no query), ranked summary mode (a query),
# or subgraph mode (a query plus `include` projections).
#
#   GraphSearch.call(query: "SynthWidget", context_scope: nil)
#   # => { mode: "summary", results: [...], pagination: { per_page: 20, current_page: 1 }, retrieval: {...} }
#
# Raises GraphMem::InvalidArgumentsError with the tool's own messages; callers map errors.
class GraphSearch
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100
  PROJECTIONS = %w[observations relations].freeze

  # @param query [String, nil] nil for catalog mode
  # @param include [Array<String>] subgraph projections: "observations" and/or "relations"
  # @param page [Integer, nil] 1-based page (default 1)
  # @param per_page [Integer, nil] 1-100 (default 20); `limit` is its legacy alias
  # @param occurred_after [String, nil] ISO 8601 bounds; `as_of` excludes the other two
  # @param max_tokens [Integer, nil] estimated token budget for the page
  # @param perspective [String, nil] "world" or "experience"
  # @param project_id [Integer, nil] only this Project root and its members (SearchFilter)
  # @param entity_types [Array<String>, nil] only these entity types (SearchFilter)
  # @param context_scope [ProjectSubtree::Result, nil] the caller's active context (a boost, never a filter)
  # @param semantic [Boolean] page only: false ranks without the vector channels (no embedding call)
  # @param ambient_context [Boolean] page only: false ignores the "default" bucket's context when
  #   `context_scope` is nil
  # @param text [Boolean] page only: false skips the text channel (Semantic mode)
  # @return [Hash] the tool's response envelope
  def self.call(query:, context_scope:, **options)
    new(query: query, context_scope: context_scope, **options).call
  end

  def initialize(query:, context_scope:, include: [], page: nil, per_page: nil, limit: nil,
                 search_in_name: true, search_in_type: true, search_in_aliases: true,
                 search_in_observations: true, project_id: nil, entity_types: nil, occurred_after: nil,
                 occurred_before: nil, as_of: nil, max_tokens: nil, perspective: nil, logger: Rails.logger,
                 semantic: true, ambient_context: true, text: true)
    @query = query
    @context_scope = context_scope
    @include = include
    @page = page
    @per_page = per_page || limit
    @search_fields = { search_in_name: search_in_name, search_in_type: search_in_type,
                       search_in_aliases: search_in_aliases, search_in_observations: search_in_observations }
    @filter_arguments = { project_id: project_id, entity_types: entity_types }
    @temporal_bounds = { occurred_after: occurred_after, occurred_before: occurred_before, as_of: as_of }
    @max_tokens = max_tokens
    @perspective = perspective
    @logger = logger
    # Only non-default values are passed on, so the tool's calls stay exactly as before.
    @retrieval_options = { semantic: semantic, ambient_context: ambient_context, text: text }.reject { |_key, value| value }
  end

  # @return [Hash]
  def call
    page, per_page = normalized_paging
    projections = normalized_projections
    temporal_window = build_temporal_window
    validate_perspective!
    max_tokens = TokenBudget.validate_max_tokens!(@max_tokens, error_class: GraphMem::InvalidArgumentsError)

    if @query.nil?
      if projections.any? || temporal_window.present? || max_tokens.present?
        raise GraphMem::InvalidArgumentsError, "include, temporal bounds and max_tokens require a query."
      end

      if !@filter_arguments[:project_id].nil? || Array(@filter_arguments[:entity_types]).any?
        raise GraphMem::InvalidArgumentsError, "project_id and entity_types require a query."
      end

      return { mode: "catalog" }.merge(EntityCatalogService.call(page: page, per_page: per_page))
    end
    raise GraphMem::InvalidArgumentsError, "Query term cannot be blank." if @query.blank?

    filter = SearchFilter.build(**@filter_arguments, **@search_fields)
    # A default filter narrows nothing: pass nil so the unfiltered code path runs unchanged.
    options = { page: page, per_page: per_page, temporal_window: temporal_window, max_tokens: max_tokens,
                perspective: @perspective, filter: (filter unless filter.default?) }
    if projections.any?
      subgraph_result(projections, **options)
    else
      Summary.call(@query, context_scope: @context_scope, retrieval_options: @retrieval_options, **options)
    end
  end

  private

  def normalized_paging
    page = @page.nil? ? DEFAULT_PAGE : @page.to_i
    per_page = @per_page.nil? ? DEFAULT_PER_PAGE : @per_page.to_i
    raise GraphMem::InvalidArgumentsError, "Page number must be 1 or greater." if page < 1
    unless per_page.between?(1, MAX_PER_PAGE)
      raise GraphMem::InvalidArgumentsError, "Per page count must be between 1 and #{MAX_PER_PAGE}."
    end

    [ page, per_page ]
  end

  def normalized_projections
    normalized = Array(@include).map(&:to_s).uniq
    unknown = normalized - PROJECTIONS
    if unknown.any?
      raise GraphMem::InvalidArgumentsError,
            "include values must be observations and/or relations; received #{unknown.join(', ')}."
    end

    normalized
  end

  def validate_perspective!
    return if @perspective.blank? || MemoryObservation::PERSPECTIVES.include?(@perspective)

    raise GraphMem::InvalidArgumentsError,
          "perspective must be one of #{MemoryObservation::PERSPECTIVES.join(', ')} (world = external fact, experience = work-log entry)."
  end

  def subgraph_result(projections, **options)
    payload = SubgraphSearchService.call(
      query: @query,
      context_scope: @context_scope,
      logger: @logger,
      include_observations: projections.include?("observations"),
      include_relations: projections.include?("relations"),
      **@search_fields,
      **options
    )

    { mode: "subgraph" }.merge(payload)
  end

  def build_temporal_window
    TemporalWindow.from_params(**@temporal_bounds)
  rescue ArgumentError => e
    raise GraphMem::InvalidArgumentsError, e.message
  end
end
