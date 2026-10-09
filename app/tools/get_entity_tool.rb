# frozen_string_literal: true

class GetEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "get_entity"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    advertised: false,
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Retrieve one known entity with its observations and relations. Pass required `entity_id` " \
    "(integer; also accepts an entity-name string); optional `include_obsolete` (bool, default false), " \
    "`include_ranked` (bool, default false), `query` (string), `observation_limit` (integer). " \
    "Do not use for keyword discovery; use `search` instead. " \
    "Do not use to page the catalog; use `search` instead. " \
    "Do not use to load many known ids as a closed subgraph; use `get_entities` instead. " \
    "Do not use for a multi-hop neighborhood; use `traverse_graph` instead. " \
    "Do not use to ask what the graph knows about a topic; use `summarize` instead. " \
    "Do not use when you only need observations sorted by trust; use `rank_observations` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to retrieve.")
    optional(:include_obsolete).filled(:bool).description("Include obsolete and superseded observations. Defaults to false.")
    optional(:include_ranked).filled(:bool).description("Sort observations by trust score descending. Defaults to false.")
    optional(:query).filled(:string).description("Optional query for relevance-ranked observations.")
    optional(:observation_limit).filled(:integer).description("Maximum observations to return per entity.")
    optional(:occurred_after).maybe(:string).description("ISO 8601 lower bound for observation occurred time.")
    optional(:occurred_before).maybe(:string).description("ISO 8601 upper bound for observation occurred time.")
    optional(:as_of).maybe(:string).description("ISO 8601 instant observations must cover (exclusive with after/before).")
    optional(:max_tokens).filled(:integer).description("Estimated token budget (chars/4) for packing the response.")
  end

  def call(entity_id:, include_obsolete: false, include_ranked: false, query: nil, observation_limit: nil,
           occurred_after: nil, occurred_before: nil, as_of: nil, max_tokens: nil)
    max_tokens = TokenBudget.validate_max_tokens!(max_tokens, error_class: FastMcp::Tool::InvalidArgumentsError)
    logger.info "Performing GetEntityTool with entity_id: #{entity_id}"
    begin
      result = EntitiesFetchService.call(
        entity_ids: [ entity_id ],
        relations: "all",
        include_obsolete: include_obsolete,
        include_ranked: include_ranked,
        query: query,
        observation_limit: observation_limit,
        temporal_window: temporal_window_for(occurred_after, occurred_before, as_of),
        max_tokens: max_tokens
      )
      entity = result[:entities].first
      relations = result[:relations]
      if entity.nil?
        # Only reachable when max_tokens could not fit even the first entity
        # (a truly missing ID raises RecordNotFound inside the service).
        raise FastMcp::Tool::InvalidArgumentsError,
              "Entity payload exceeds the max_tokens budget; raise max_tokens or omit it."
      end

      response = {
        entity_id: entity[:entity_id],
        name: entity[:name],
        entity_type: entity[:entity_type],
        description: entity[:description],
        created_at: entity[:created_at],
        updated_at: entity[:updated_at],
        observations_truncated: entity[:observations_truncated],
        observations: entity[:observations].map do |observation|
          observation.except(:content).merge(observation_content: observation[:content])
        end,
        relations_from: relations.filter_map do |relation|
          next unless relation[:from_entity_id] == entity_id

          relation.slice(
            :relation_id, :to_entity_id, :relation_type, :weight, :confidence,
            :properties, :created_at, :updated_at
          )
        end,
        relations_to: relations.filter_map do |relation|
          next unless relation[:to_entity_id] == entity_id

          relation.slice(
            :relation_id, :from_entity_id, :relation_type, :weight, :confidence,
            :properties, :created_at, :updated_at
          )
        end
      }
      response[:token_budget] = result[:token_budget] if result[:token_budget]
      response[:temporal] = result[:temporal] if result[:temporal]
      # The service fits the pre-reshape payload; the reshaped response can
      # still exceed the budget — a single entity can't be split further.
      if max_tokens.present? && TokenBudget.estimate(response) > max_tokens
        raise FastMcp::Tool::InvalidArgumentsError,
              "Entity payload exceeds the max_tokens budget; raise max_tokens or omit it."
      end
      response
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in GetEntityTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search`, then retry `get_entities` with a known id."
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue StandardError => e
      logger.error "GetEntityTool unexpected error: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
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
