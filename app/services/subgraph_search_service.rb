# frozen_string_literal: true

class SubgraphSearchService
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100
  MAX_TEMPORAL_CANDIDATES = 500

  def self.call(**args)
    new(**args).call
  end

  def initialize(query:, context_scope: nil, logger: Rails.logger, page: nil, per_page: nil,
                 search_in_name: true, search_in_type: true, search_in_observations: true,
                 search_in_aliases: true, include_observations: true, include_relations: true,
                 temporal_window: nil, max_tokens: nil)
    @query = query
    @context_scope = context_scope
    @logger = logger
    @page = page.nil? ? DEFAULT_PAGE : page.to_i
    @per_page = per_page.nil? ? DEFAULT_PER_PAGE : per_page.to_i
    @search_fields = {
      name: search_in_name,
      type: search_in_type,
      observations: search_in_observations,
      aliases: search_in_aliases
    }
    @include_observations = include_observations
    @include_relations = include_relations
    @extraction = TemporalQueryParser.apply(query, temporal_window: temporal_window)
    @temporal_window = @extraction.window
    @effective_query = @extraction.effective_query
    @max_tokens = max_tokens
  end

  def call
    validate!

    context_ids = @context_scope&.entity_ids
    ids, in_window = candidate_ids(context_ids)
    # A purely temporal query's ordering IS the in-window observation count;
    # re-ranking it by type/structure would discard the only relevance signal.
    # With text plus a window, rank the in-window and out-of-window partitions
    # separately so every in-window candidate outranks every out-of-window one
    # (the partition would otherwise be lost inside the relevance booster).
    rank = ->(list) {
      SearchRelevanceBooster.rank_entity_ids(
        list,
        query: @effective_query,
        context_entity_ids: context_ids
      )
    }
    matching_ids =
      if @extraction.temporal_only? || @temporal_fallback
        ids
      elsif in_window
        hot, cold = ids.partition { |id| in_window.include?(id) }
        rank.call(hot) + rank.call(cold)
      else
        rank.call(ids)
      end
    page_ids = matching_ids.slice((@page - 1) * @per_page, @per_page) || []

    entities = entities_for(page_ids)
    relations = @include_relations ? relations_for(page_ids) : nil

    response = {
      entities: entities,
      pagination: pagination_for(matching_ids.size),
      retrieval: retrieval_for(context_ids)
    }
    response[:relations] = relations if relations
    apply_token_budget!(response)
    response
  end

  private

  def validate!
    raise FastMcp::Tool::InvalidArgumentsError, "Query term cannot be blank." if @query.blank?

    unless @search_fields.values.any?
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one search field (name, type, aliases, observations) must be enabled."
    end
    raise FastMcp::Tool::InvalidArgumentsError, "Page number must be 1 or greater." if @page < 1
    return if @per_page.between?(1, MAX_PER_PAGE)

    raise FastMcp::Tool::InvalidArgumentsError,
          "Per page count must be between 1 and #{MAX_PER_PAGE}."
  end

  # Returns [candidate_ids, in_window_set_or_nil]. Purely temporal queries
  # (phrase stripped to nothing) list entities by in-window observation
  # count — capped at MAX_TEMPORAL_CANDIDATES with a diagnostic flag — and
  # date-windowed queries whose residual terms match nothing fall back to the
  # same listing. Otherwise text+vector matches are ordered with the window
  # partition: the temporal lookup only ranks the candidates the other
  # channels already produced, never the whole graph.
  def candidate_ids(context_ids)
    if @extraction.temporal_only?
      ids = temporal_candidate_ids(context_ids)
      return [ ids, nil ]
    end

    ids = merge_vector_ids(text_matching_ids)

    # Fallback: a windowed query whose residual terms match nothing behaves
    # like a temporal-only query instead of returning an empty subgraph.
    # Residual terms are matched individually: filler words that survive
    # ("changes") would otherwise empty the whole-phrase match and the
    # fallback would inject unrelated in-window entities — "alpha changes
    # in august 2026" must still find Alpha.
    if @temporal_window && ids.empty?
      term_ids = TemporalQueryParser.residual_terms(@effective_query)
                                    .flat_map { |term| text_matching_ids(term) }.uniq
      if term_ids.empty?
        @temporal_fallback = true
        return [ temporal_candidate_ids(context_ids), nil ]
      end
      ids = term_ids
    end
    return [ ids, nil ] unless @temporal_window

    scoped = context_ids.present? ? ids & context_ids : ids
    in_window = if scoped.empty?
      Set.new
    else
      TemporalSearchStrategy.new.search(@temporal_window, limit: nil, entity_ids: scoped).to_set
    end
    [ ids, in_window ]
  end

  # In-window entity ids ordered by observation count, capped so a broad
  # window cannot pluck every entity id before paging. The cap is reported
  # via retrieval.temporal.candidates_truncated.
  def temporal_candidate_ids(context_ids)
    ids = TemporalSearchStrategy.new.search(
      @temporal_window, limit: MAX_TEMPORAL_CANDIDATES + 1, entity_ids: context_ids
    )
    @temporal_candidates_truncated = ids.size > MAX_TEMPORAL_CANDIDATES
    ids.first(MAX_TEMPORAL_CANDIDATES)
  end

  def text_matching_ids(term = nil)
    base_query = MemoryEntity.distinct
    conditions = []
    params = { like_query_term: "%#{(term || @effective_query).downcase}%" }

    conditions << "LOWER(memory_entities.name) LIKE :like_query_term" if @search_fields[:name]
    conditions << "LOWER(memory_entities.entity_type) LIKE :like_query_term" if @search_fields[:type]
    conditions << "LOWER(memory_entities.aliases) LIKE :like_query_term" if @search_fields[:aliases]
    if @search_fields[:observations]
      base_query = base_query.left_joins(:memory_observations)
      conditions << "(memory_observations.status = :active_status AND LOWER(memory_observations.content) LIKE :like_query_term)"
      params[:active_status] = MemoryObservation::ACTIVE_STATUS
    end

    base_query.where(conditions.join(" OR "), params).pluck(:id).uniq
  end

  def merge_vector_ids(matching_ids)
    vector_results = VectorSearchStrategy.new.search(@effective_query, limit: @per_page * 2)
    (matching_ids + vector_results.map { |result| result.entity.id }).uniq
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    @logger.debug "SubgraphSearchService: vector search unavailable, using text only — #{e.message}"
    matching_ids
  end

  def entities_for(entity_ids)
    return [] if entity_ids.empty?

    order_sql = entity_ids.map.with_index { |id, index| "WHEN #{id} THEN #{index}" }.join(" ")
    MemoryEntity.where(id: entity_ids)
                .includes(:active_memory_observations)
                .order(Arel.sql("CASE id #{order_sql} END"))
                .map { |entity| entity_payload(entity) }
  end

  def entity_payload(entity)
    payload = {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601
    }
    if @include_observations
      observations = entity.active_memory_observations
      observations = observations.select { |observation| @temporal_window.covers?(observation) } if @temporal_window
      payload[:observations] = observations.map do |observation|
        MemoryObservationSerializer.call(observation)
      end
    end
    payload
  end

  # Packs entities (then relations for whatever budget remains) under the
  # optional token budget and records the result in retrieval diagnostics.
  # Relations are scoped to the kept entity endpoints first — a relation whose
  # entities were dropped by the budget is never returned dangling.
  def apply_token_budget!(response)
    return if @max_tokens.blank?

    # Seed the diagnostics with worst-case digits so the item-less envelope
    # counted below over-covers them — real values written after the fit are
    # always narrower, so the final response stays under budget (S6).
    response[:retrieval][:token_budget] = TokenBudget.diagnostics(
      max_tokens: @max_tokens, estimated_tokens: 9_999_999_999, truncated: false,
      envelope_tokens: 9_999_999_999, items_before: 9_999_999_999, items_after: 9_999_999_999
    )
    envelope = response.merge(entities: [], relations: [])
    entities_fit = TokenBudget.fit_with_envelope(response[:entities], envelope: envelope, max_tokens: @max_tokens)
    budget_left = @max_tokens - entities_fit.envelope_tokens - entities_fit.estimated_tokens
    fetched_ids = response[:entities].map { |entity| entity[:entity_id] }.to_set
    response[:entities] = entities_fit.items

    used = entities_fit.estimated_tokens
    truncated = entities_fit.truncated

    relations_before = response[:relations].is_a?(Array) ? response[:relations].size : 0

    if response[:relations].is_a?(Array)
      # Drop relations that touch a budget-dropped entity; relations between
      # kept entities and outside the fetched set stay (they never dangle).
      dropped_ids = fetched_ids - entities_fit.items.map { |entity| entity[:entity_id] }
      scoped_relations = response[:relations].reject do |relation|
        dropped_ids.include?(relation[:from_entity_id]) || dropped_ids.include?(relation[:to_entity_id])
      end
      relations_fit = TokenBudget.fit(scoped_relations, max_tokens: [ budget_left, 0 ].max)
      response[:relations] = relations_fit.items
      used += relations_fit.estimated_tokens
      truncated ||= relations_fit.truncated
    end

    response[:retrieval][:token_budget] = TokenBudget.diagnostics(
      max_tokens: @max_tokens, estimated_tokens: used, truncated: truncated,
      envelope_tokens: entities_fit.envelope_tokens,
      items_before: entities_fit.items_before + relations_before,
      items_after: entities_fit.items_after + (response[:relations]&.size || 0)
    )
  end

  def relations_for(entity_ids)
    return [] if entity_ids.empty?

    MemoryRelation.where(from_entity_id: entity_ids, to_entity_id: entity_ids)
                  .map { |relation| GraphTraversalSerializer.relation_json(relation) }
  end

  def pagination_for(total_entities)
    {
      total_entities: total_entities,
      per_page: @per_page,
      current_page: @page,
      total_pages: [ (total_entities.to_f / @per_page).ceil, 1 ].max
    }
  end

  def retrieval_for(context_ids)
    {
      scope_entity_count: context_ids&.size,
      scope_truncated: @context_scope&.truncated == true,
      scope_max_entities: @context_scope&.max_entities
    }.merge(@temporal_window.present? ? { temporal: temporal_diagnostic } : {})
  end

  def temporal_diagnostic
    @extraction.diagnostic.merge(
      fallback: (@temporal_fallback ? "temporal_only" : nil),
      candidates_truncated: (@temporal_candidates_truncated ? true : nil)
    ).compact
  end
end
