# frozen_string_literal: true

class GetEntitiesTool < ApplicationTool
  def self.tool_name
    "get_entities"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Load one or more known entities with observations and a relation projection. Pass required `entity_ids` " \
    "(array of IDs or resolvable names); optional `relations` (all or internal), `include_obsolete`, `include_ranked`, " \
    "`query`, `observation_limit`, `occurred_after`/`occurred_before`/`as_of` (ISO 8601) to restrict observations " \
    "to a temporal window, and `max_tokens` to pack the response under an estimated token budget. One unique ID " \
    "defaults relations to all incident edges; multiple IDs default " \
    "to internal edges only. Returns entities in input order plus missing_entity_ids. " \
    "Do not use for keyword discovery or catalog paging; use `search` instead. " \
    "Do not use for multi-hop neighbor expansion; use `traverse_graph` instead. " \
    "Do not use for synthesized prose; use `summarize` instead."

  arguments do
    required(:entity_ids).array(:integer).description("Entity IDs to load; name strings are resolved before validation.")
    optional(:relations).filled(:string).description("Relation projection: all or internal. Defaults by entity count.")
    optional(:include_obsolete).filled(:bool).description("Include obsolete and superseded observations.")
    optional(:include_ranked).filled(:bool).description("Sort observations by trust score.")
    optional(:query).filled(:string).description("Rank observations by relevance to this query.")
    optional(:observation_limit).filled(:integer).description("Maximum observations returned per entity.")
    optional(:occurred_after).maybe(:string).description("ISO 8601 lower bound for observation occurred time.")
    optional(:occurred_before).maybe(:string).description("ISO 8601 upper bound for observation occurred time.")
    optional(:as_of).maybe(:string).description("ISO 8601 instant observations must cover (exclusive with after/before).")
    optional(:max_tokens).filled(:integer).description("Estimated token budget (chars/4) for packing the response.")
  end

  def call(entity_ids:, relations: nil, include_obsolete: false, include_ranked: false,
           query: nil, observation_limit: nil, occurred_after: nil, occurred_before: nil,
           as_of: nil, max_tokens: nil)
    max_tokens = TokenBudget.validate_max_tokens!(max_tokens, error_class: FastMcp::Tool::InvalidArgumentsError)
    EntitiesFetchService.call(
      entity_ids: entity_ids,
      relations: relations,
      include_obsolete: include_obsolete,
      include_ranked: include_ranked,
      query: query,
      observation_limit: observation_limit,
      temporal_window: temporal_window_for(occurred_after, occurred_before, as_of),
      max_tokens: max_tokens
    )
  rescue ActiveRecord::RecordNotFound
    missing_id = Array(entity_ids).first
    raise McpGraphMemErrors::ResourceNotFound.new(
      "Entity with ID=#{missing_id} not found.",
      next_move: "Call `search` to find the entity, then retry `get_entities` with known ids."
    )
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "GetEntitiesTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def temporal_window_for(occurred_after, occurred_before, as_of)
    TemporalWindow.from_params(
      occurred_after: occurred_after,
      occurred_before: occurred_before,
      as_of: as_of
    )
  rescue ArgumentError => e
    raise FastMcp::Tool::InvalidArgumentsError, e.message
  end
end
