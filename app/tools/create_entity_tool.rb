# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  DEDUP_DISTANCE_THRESHOLD = 0.25

  def self.tool_name
    "create_entity"
  end

  description "Create a new entity in the graph memory database."

  arguments do
    required(:name).filled(:string).description("The unique name for the new entity.")
    required(:entity_type).filled(:string).description("The type classification for the new entity (e.g., 'Project', 'Task', 'Issue').")
    optional(:observations).array(:string).description("Optional list of initial observation strings associated with the entity.")
    optional(:aliases).maybe(:string).description("Optional pipe-separated string of alternative names for the entity.")
    optional(:description).maybe(:string).description("Optional short description of the entity.")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: {
        name: { type: "string", description: "The name of the entity" },
        entity_type: { type: "string", description: "The type of the entity" },
        observations: { type: "array", items: { type: "string" }, description: "Optional list of initial observation strings associated with the entity." },
        aliases: { type: "string", description: "Optional pipe-separated string of alternative names for the entity." },
        description: { type: "string", description: "Optional short description of the entity." }
      },
      required: [ "name", "entity_type" ]
    }
  end

  def call(name:, entity_type:, observations: [], aliases: nil, description: nil)
    logger.info "Performing CreateEntityTool with name: #{name}, type: #{entity_type}"

    similar = find_similar_entity(name, entity_type)
    if similar
      return {
        warning: "A similar entity already exists. Use update_entity or create_observation to add information to it instead of creating a duplicate.",
        existing_entity: {
          entity_id: similar.entity.id,
          name: similar.entity.name,
          entity_type: similar.entity.entity_type,
          description: similar.entity.description,
          aliases: similar.entity.aliases,
          similarity_distance: similar.distance.round(4)
        }
      }
    end

    new_entity = ActiveRecord::Base.transaction do
      entity = MemoryEntity.create!(
        name: name,
        entity_type: entity_type,
        aliases: aliases,
        description: description
      )

      observations.each do |obs_content|
        MemoryObservation.create!(
          memory_entity: entity,
          content: obs_content
        )
      end

      entity
    end
    logger.info "Created entity: #{new_entity.inspect}"

    {
      entity_id: new_entity.id,
      name: new_entity.name,
      entity_type: new_entity.entity_type,
      description: new_entity.description,
      created_at: new_entity.created_at.iso8601,
      updated_at: new_entity.updated_at.iso8601,
      aliases: new_entity.aliases,
      memory_observations_count: new_entity.memory_observations.count
    }
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
    logger.error "InvalidArguments in CreateEntityTool: #{error_message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, error_message
  rescue StandardError => e
    logger.error "InternalServerError in CreateEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in CreateEntityTool: #{e.message}"
  end

  private

  def find_similar_entity(name, entity_type)
    composite = "#{entity_type}: #{name}"
    vector_strategy = VectorSearchStrategy.new
    results = vector_strategy.search(composite, limit: 1)
    result = results.first
    return result if result && result.distance < DEDUP_DISTANCE_THRESHOLD

    nil
  rescue StandardError => e
    logger.debug "CreateEntityTool: dedup check unavailable — #{e.message}"
    nil
  end
end
