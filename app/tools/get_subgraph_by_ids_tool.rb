# frozen_string_literal: true

class GetSubgraphByIdsTool < ApplicationTool
  def self.tool_name
    "get_subgraph_by_ids"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    advertised: false,
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Load a known id set as a closed subgraph: those entities, their observations, and only relations whose " \
    "both ends are in the set. Pass required `entity_ids` (array of integers); optional `query` (string), " \
    "`observation_limit` (integer). Do not use to discover entities by text; use `search` instead. " \
    "Do not use for one id's complete incident relations; use `get_entities` instead. " \
    "Do not use to expand unknown neighbors; use `traverse_graph` instead."

  # Defines arguments for fast-mcp validation.
  arguments do
    required(:entity_ids).array(:integer).description("An array of entity IDs to include in the subgraph.")
    optional(:query).filled(:string).description("Optional query for relevance-ranked observations.")
    optional(:observation_limit).filled(:integer).description("Maximum observations per entity.")
  end

  def tool_input_schema
    {
      type: :object,
      properties: {
        entity_ids: {
          type: :array,
          items: { type: :integer },
          minItems: 1,
          description: "An array of entity IDs to retrieve."
        }
      },
      required: [ :entity_ids ]
    }.freeze
  end

  def tool_output_schema
    {
      type: :object,
      properties: {
        entities: {
          type: :array,
          items: {
            type: :object,
            properties: {
              entity_id: { type: :integer },
              name: { type: :string },
              entity_type: { type: :string },
              observations: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    observation_id: { type: :integer },
                    content: { type: :string },
                    confidence: { type: [ :number, :null ] },
                    source: { type: [ :string, :null ] },
                    valid_from: { type: [ :string, :null ], format: "date-time" },
                    valid_until: { type: [ :string, :null ], format: "date-time" },
                    tags: { type: :array, items: { type: :string } },
                    status: { type: :string, enum: MemoryObservation::STATUSES },
                    obsoleted_at: { type: [ :string, :null ], format: "date-time" },
                    obsolescence_reason: { type: [ :string, :null ] },
                    superseded_by_id: { type: [ :integer, :null ] },
                    created_at: { type: :string, format: "date-time" },
                    updated_at: { type: :string, format: "date-time" }
                  },
                  required: [ :observation_id, :content, :status, :created_at, :updated_at ]
                }
              },
              created_at: { type: :string, format: "date-time" },
              updated_at: { type: :string, format: "date-time" }
            },
            required: [ :entity_id, :name, :entity_type, :observations, :created_at, :updated_at ]
          }
        },
        relations: {
          type: :array,
          items: {
            type: :object,
            properties: {
              relation_id: { type: :integer },
              from_entity_id: { type: :integer },
              to_entity_id: { type: :integer },
              relation_type: { type: :string },
              weight: { type: [ :number, :null ] },
              confidence: { type: [ :number, :null ] },
              properties: { type: :object },
              created_at: { type: :string, format: "date-time" },
              updated_at: { type: :string, format: "date-time" }
            },
            required: [ :relation_id, :from_entity_id, :to_entity_id, :relation_type, :created_at, :updated_at ]
          }
        }
      },
      required: [ :entities, :relations ]
    }.freeze
  end

  def call(entity_ids:, query: nil, observation_limit: nil)
    result = EntitiesFetchService.call(
      entity_ids: entity_ids,
      relations: "internal",
      query: query,
      observation_limit: observation_limit,
      strict_single: false,
      always_rank_observations: true
    )

    {
      entities: result[:entities].map do |entity|
        entity.slice(:entity_id, :name, :entity_type, :observations, :created_at, :updated_at)
      end,
      relations: result[:relations],
      missing_entity_ids: result[:missing_entity_ids]
    }
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue ActiveRecord::RecordNotFound => e
    logger.error "ResourceNotFound in GetSubgraphByIDsTool: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::ResourceNotFound.new(
      "One or more requested entities were not found.",
      next_move: "Call `search` to find matching entities, then retry `get_entities` with known ids."
    )
  rescue StandardError => e
    logger.error "InternalServerError in GetSubgraphByIDsTool: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
