# frozen_string_literal: true

class SubgraphSearchService
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100

  def self.call(**args)
    new(**args).call
  end

  def initialize(query:, context_scope: nil, logger: Rails.logger, page: nil, per_page: nil,
                 search_in_name: true, search_in_type: true, search_in_observations: true,
                 search_in_aliases: true, include_observations: true, include_relations: true)
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
  end

  def call
    validate!

    matching_ids = text_matching_ids
    matching_ids = merge_vector_ids(matching_ids)
    context_ids = @context_scope&.entity_ids
    matching_ids = SearchRelevanceBooster.rank_entity_ids(
      matching_ids,
      query: @query,
      context_entity_ids: context_ids
    )
    page_ids = matching_ids.slice((@page - 1) * @per_page, @per_page) || []

    response = {
      entities: entities_for(page_ids),
      pagination: pagination_for(matching_ids.size),
      retrieval: retrieval_for(context_ids)
    }
    response[:relations] = relations_for(page_ids) if @include_relations
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

  def text_matching_ids
    base_query = MemoryEntity.distinct
    conditions = []
    params = { like_query_term: "%#{@query.downcase}%" }

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
    vector_results = VectorSearchStrategy.new.search(@query, limit: @per_page * 2)
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
      payload[:observations] = entity.active_memory_observations.map do |observation|
        MemoryObservationSerializer.call(observation)
      end
    end
    payload
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
    }
  end
end
