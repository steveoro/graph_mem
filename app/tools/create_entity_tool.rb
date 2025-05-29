# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'create_entity'
  end

  description "Create a new entity in the graph memory database."

  arguments do
    required(:name).filled(:string).description("The unique name for the new entity.")
    required(:entity_type).filled(:string).description("The type classification for the new entity (e.g., 'Project', 'Task', 'Issue').")
    optional(:observations).array(:string).description("Optional list of initial observation strings associated with the entity.")
  end

  # def self.input_schema
  #   schema
  # end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  # Needed, otherwise the LLM will not figure out the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: {
        name: { type: "string", description: "The name of the entity" },
        entity_type: { type: "string", description: "The type of the entity" },
        observations: { type: "array", items: { type: "string" }, description: "Optional list of initial observation strings associated with the entity." }
      },
      required: [ "name", "entity_type" ]
    }
  end

  def call(name:, entity_type:, observations: [])
    logger.info "Performing CreateEntityTool with name: #{name}, type: #{entity_type}"

    # Wrap the core logic in a transaction
    new_entity = ActiveRecord::Base.transaction do
      entity = MemoryEntity.create!(
        name: name,
        entity_type: entity_type
      )

      # Add initial observations if provided
      observations.each do |obs_content|
        MemoryObservation.create!(
          memory_entity: entity,
          content: obs_content
        )
      end

      entity # Return the entity from the transaction block
    end
    logger.info "Created entity: #{new_entity.inspect}"

    # Format output hash - return hash directly
    {
      id: new_entity.id,
      name: new_entity.name,
      entity_type: new_entity.entity_type,
      created_at: new_entity.created_at.iso8601,
      updated_at: new_entity.updated_at.iso8601,
      observations_count: new_entity.memory_observations.count # Ensure this reflects observations within the transaction
    }
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
    logger.error "InvalidArguments in CreateEntityTool: #{error_message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, error_message
  rescue StandardError => e
    logger.error "InternalServerError in CreateEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in CreateEntityTool: #{e.message}"
  end
end
