# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'create_entity'
  end

  description "Create a new entity in the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "The unique name for the new entity."
      },
      entity_type: {
        type: "string",
        description: "The type classification for the new entity (e.g., 'Project', 'Task', 'Issue')."
      },
      observations: {
        type: "array",
        items: { type: "string" },
        description: "Optional list of initial observation strings associated with the entity."
      }
    },
    required: ["name", "entity_type"]
  })

  def call(name:, entity_type:, observations: [])
    logger.info "Creating entity with name: #{name}, type: #{entity_type}"

    # Validate inputs
    return validation_error("Name cannot be blank") if name.blank?
    return validation_error("Entity type cannot be blank") if entity_type.blank?

    # Wrap the core logic in a transaction
    new_entity = ActiveRecord::Base.transaction do
      entity = MemoryEntity.create!(
        name: name,
        entity_type: entity_type
      )

      # Add initial observations if provided
      observations.each do |obs_content|
        next if obs_content.blank?
        MemoryObservation.create!(
          memory_entity: entity,
          content: obs_content
        )
      end

      entity # Return the entity from the transaction block
    end

    logger.info "Created entity: #{new_entity.name} (ID: #{new_entity.id})"

    # Format output hash
    result = {
      entity_id: new_entity.id.to_s,
      name: new_entity.name,
      entity_type: new_entity.entity_type,
      created_at: new_entity.created_at.iso8601,
      updated_at: new_entity.updated_at.iso8601,
      observations_count: new_entity.memory_observations.count
    }

    success_response(result)
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
    logger.error "Validation error in CreateEntityTool: #{error_message}"
    validation_error(error_message)
  rescue ActiveRecord::RecordNotUnique => e
    error_message = "Entity with name '#{name}' already exists"
    logger.error "Uniqueness error in CreateEntityTool: #{error_message}"
    validation_error(error_message)
  rescue StandardError => e
    logger.error "Error in CreateEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An internal server error occurred while creating the entity: #{e.message}")
  end
end
