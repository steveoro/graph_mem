# frozen_string_literal: true

class GetSubgraphByIdsTool < ApplicationTool
  def self.tool_name
    "get_subgraph_by_ids"
  end

  description "Retrieves a specific set of entities by their IDs, including their observations, " \
    "and all relations that exist exclusively between them."

  # Defines arguments for fast-mcp validation.
  arguments do
    required(:entity_ids).array(:integer).description("An array of entity IDs to include in the subgraph.")
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
                    created_at: { type: :string, format: "date-time" },
                    updated_at: { type: :string, format: "date-time" }
                  },
                  required: [ :observation_id, :content, :created_at, :updated_at ]
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

  def call(entity_ids:)
    # super # Validate input -> This is handled by fast-mcp's arguments DSL now
    entity_ids = entity_ids.uniq

    if entity_ids.empty?
      # This is an invalid argument scenario
      error_message = "entity_ids array cannot be empty."
      logger.error "InvalidArgumentsError in GetSubgraphByIDsTool: #{error_message}"
      raise FastMcp::Tool::InvalidArgumentsError, error_message
    end

    # Fetch entities with their observations
    entities_data = MemoryEntity.where(id: entity_ids).includes(:memory_observations).map do |entity|
      {
        entity_id: entity.id,
        name: entity.name,
        entity_type: entity.entity_type,
        observations: entity.memory_observations.map do |obs|
          {
            observation_id: obs.id,
            content: obs.content,
            created_at: obs.created_at.iso8601,
            updated_at: obs.updated_at.iso8601
          }
        end,
        created_at: entity.created_at.iso8601,
        updated_at: entity.updated_at.iso8601
      }
    end

    # Fetch relations that are exclusively between the given entity_ids
    relations_data = MemoryRelation
      .where(from_entity_id: entity_ids, to_entity_id: entity_ids)
      .map do |relation|
      {
        relation_id: relation.id,
        from_entity_id: relation.from_entity_id,
        to_entity_id: relation.to_entity_id,
        relation_type: relation.relation_type,
        created_at: relation.created_at.iso8601,
        updated_at: relation.updated_at.iso8601
      }
    end

    {
      entities: entities_data,
      relations: relations_data
    }
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue ActiveRecord::RecordNotFound => e
    logger.error "ResourceNotFound in GetSubgraphByIDsTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::ResourceNotFound, "Error finding records: #{e.message}"
  rescue StandardError => e
    logger.error "InternalServerError in GetSubgraphByIDsTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred: #{e.message}"
  end
end
