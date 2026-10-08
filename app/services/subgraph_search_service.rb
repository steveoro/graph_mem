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
    matching_ids = candidate_ids(context_ids)
    matching_ids = SearchRelevanceBooster.rank_entity_ids(
      matching_ids,
      query: @effective_query,
      context_entity_ids: context_ids
    )
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

  # Purely temporal queries (phrase stripped to nothing) list entities by
  # in-window observation count; otherwise text+vector matches are boosted by
  # the window — temporally-matching ids come first, no unrelated injections.
  def candidate_ids(context_ids)
    if @extraction.temporal_only?
      return TemporalSearchStrategy.new.search(
        @temporal_window, limit: MAX_TEMPORAL_CANDIDATES, entity_ids: context_ids
      )
    end

    matching_ids = merge_vector_ids(text_matching_ids)
    return matching_ids unless @temporal_window

    temporal_ids = TemporalSearchStrategy.new.search(
      @temporal_window, limit: MAX_TEMPORAL_CANDIDATES, entity_ids: context_ids
    ).to_set
    matching_ids.partition { |id| temporal_ids.include?(id) }.flatten
  end

  def text_matching_ids
    base_query = MemoryEntity.distinct
    conditions = []
    params = { like_query_term: "%#{@effective_query.downcase}%" }

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

    budget = @max_tokens.to_i
    entities_fit = TokenBudget.fit(response[:entities], max_tokens: budget)
    response[:entities] = entities_fit.items

    used = entities_fit.estimated_tokens
    truncated = entities_fit.truncated
    dropped = entities_fit.dropped_count

    if response[:relations].is_a?(Array)
      kept_ids = entities_fit.items.map { |entity| entity[:entity_id] }.to_set
      scoped_relations = response[:relations].select do |relation|
        kept_ids.include?(relation[:from_entity_id]) && kept_ids.include?(relation[:to_entity_id])
      end
      relations_fit = TokenBudget.fit(scoped_relations, max_tokens: [ budget - used, 0 ].max)
      response[:relations] = relations_fit.items
      used += relations_fit.estimated_tokens
      truncated ||= relations_fit.truncated
      dropped += relations_fit.dropped_count
    end

    response[:retrieval][:token_budget] = TokenBudget.diagnostics(
      max_tokens: budget, estimated_tokens: used, truncated: truncated,
      items_before: entities_fit.items_before, items_after: entities_fit.items_after
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
    }.merge(@temporal_window.present? ? { temporal: @extraction.diagnostic } : {})
  end
end
