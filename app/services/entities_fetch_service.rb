# frozen_string_literal: true

class EntitiesFetchService
  RELATION_MODES = %w[all internal].freeze

  def self.call(**args)
    new(**args).call
  end

  def initialize(entity_ids:, relations: nil, include_obsolete: false, include_ranked: false,
                 query: nil, observation_limit: nil, strict_single: true,
                 always_rank_observations: false, temporal_window: nil, max_tokens: nil)
    @entity_ids = Array(entity_ids).map(&:to_i).uniq
    @relations_mode = relations.presence || default_relations_mode
    @include_obsolete = include_obsolete
    @include_ranked = include_ranked
    @query = query
    @observation_limit = observation_limit
    @strict_single = strict_single
    @always_rank_observations = always_rank_observations
    @extraction = TemporalQueryParser.apply(query, temporal_window: temporal_window)
    @temporal_window = @extraction.window
    @effective_query = @extraction.effective_query
    @max_tokens = max_tokens
  end

  def call
    validate!

    entities_by_id = MemoryEntity
                     .where(id: @entity_ids)
                     .includes(:memory_observations, :active_memory_observations)
                     .index_by(&:id)
    missing_ids = @entity_ids - entities_by_id.keys
    if @strict_single && @entity_ids.one? && missing_ids.any?
      raise ActiveRecord::RecordNotFound, "Entity with ID=#{@entity_ids.first} not found."
    end

    entities = @entity_ids.filter_map { |id| entities_by_id[id] }.map { |entity| entity_payload(entity) }
    relations = relation_payloads

    result = {
      entities: entities,
      relations: relations,
      missing_entity_ids: missing_ids,
      relation_scope: @relations_mode
    }
    result[:temporal] = @extraction.diagnostic if @temporal_window
    apply_token_budget!(result)
    result
  end

  private

  def validate!
    if @entity_ids.empty?
      raise FastMcp::Tool::InvalidArgumentsError, "entity_ids array cannot be empty."
    end
    return if @relations_mode.in?(RELATION_MODES)

    raise FastMcp::Tool::InvalidArgumentsError,
          "relations must be one of: #{RELATION_MODES.join(', ')}."
  end

  def default_relations_mode
    @entity_ids.one? ? "all" : "internal"
  end

  def entity_payload(entity)
    pool = @include_obsolete ? entity.memory_observations : entity.active_memory_observations
    pool = pool.select { |observation| @temporal_window.covers?(observation) } if @temporal_window
    observations = ranked_observations(pool)

    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      observations_truncated: @observation_limit.present? && observations.size < pool.size,
      observations: observations.map { |observation| MemoryObservationSerializer.call(observation) }
    }
  end

  def ranked_observations(observations)
    if @effective_query.present?
      ObservationRankingService.rank(observations, query: @effective_query, limit: @observation_limit)
    elsif @include_ranked || @always_rank_observations || @observation_limit.present?
      ObservationRankingService.rank(observations, mode: "trust", limit: @observation_limit)
    else
      observations
    end
  end

  def relation_payloads
    scope =
      if @relations_mode == "internal"
        MemoryRelation.where(from_entity_id: @entity_ids, to_entity_id: @entity_ids)
      else
        MemoryRelation.where(from_entity_id: @entity_ids)
                      .or(MemoryRelation.where(to_entity_id: @entity_ids))
      end

    scope.distinct.order(:id).map { |relation| GraphTraversalSerializer.relation_json(relation) }
  end

  # Packs entities (then relations for whatever budget remains) under the
  # optional token budget and records the result for the caller.
  def apply_token_budget!(result)
    return if @max_tokens.blank?

    # Seed the diagnostics with worst-case digits so the item-less envelope
    # counted below over-covers them — real values written after the fit are
    # always narrower, so the final response stays under budget (S6).
    result[:token_budget] = TokenBudget.diagnostics_placeholder(max_tokens: @max_tokens)
    # WRAPPER_RESERVE covers the fields ToolSuccessResponse appends after the
    # tool returns — they are part of the delivered structuredContent.
    envelope = result.merge(entities: [], relations: []).merge(TokenBudget::WRAPPER_RESERVE)
    fetched_ids = result[:entities].map { |entity| entity[:entity_id] }.to_set
    relations_before = result[:relations].size
    entities_fit = TokenBudget.fit_with_envelope(result[:entities], envelope: envelope, max_tokens: @max_tokens)
    result[:entities] = entities_fit.items
    budget_left = @max_tokens - entities_fit.envelope_tokens - entities_fit.estimated_tokens

    used = entities_fit.estimated_tokens
    truncated = entities_fit.truncated

    # Drop relations that touch a budget-dropped entity, but keep incident
    # edges whose far endpoint was never part of the fetched set — those
    # relations still resolve to real entities and never dangle.
    dropped_ids = fetched_ids - entities_fit.items.map { |entity| entity[:entity_id] }
    scoped_relations = result[:relations].reject do |relation|
      dropped_ids.include?(relation[:from_entity_id]) || dropped_ids.include?(relation[:to_entity_id])
    end
    relations_fit = TokenBudget.fit(scoped_relations, max_tokens: [ budget_left, 0 ].max)
    result[:relations] = relations_fit.items
    used += relations_fit.estimated_tokens
    truncated ||= relations_fit.truncated

    result[:token_budget] = TokenBudget.diagnostics(
      max_tokens: @max_tokens, estimated_tokens: used, truncated: truncated,
      envelope_tokens: entities_fit.envelope_tokens,
      items_before: entities_fit.items_before + relations_before,
      items_after: result[:entities].size + result[:relations].size
    )
  end
end
