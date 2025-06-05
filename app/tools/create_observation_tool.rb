# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'create_observation'
  end

  description "Add a new observation to an existing entity in the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      entity_id: {
        type: "string",
        description: "The ID of the entity to add the observation to."
      },
      content: {
        type: "string",
        description: "The content of the observation to add."
      }
    },
    required: ["entity_id", "content"]
  })

  def call(entity_id:, content:)
    logger.info "Creating observation for entity_id: #{entity_id}"

    # Validate inputs
    return validation_error("Entity ID cannot be blank") if entity_id.blank?
    return validation_error("Content cannot be blank") if content.blank?

    # Find the entity
    entity = MemoryEntity.find_by(id: entity_id)
    return not_found_error("Entity", entity_id) unless entity

    # Create the observation
    observation = MemoryObservation.create!(
      memory_entity: entity,
      content: content
    )

    logger.info "Created observation: #{observation.id} for entity: #{entity.name}"

    # Format output hash
    result = {
      observation_id: observation.id.to_s,
      entity_id: entity.id.to_s,
      entity_name: entity.name,
      content: observation.content,
      created_at: observation.created_at.iso8601,
      updated_at: observation.updated_at.iso8601
    }

    success_response(result)
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation failed: #{e.record.errors.full_messages.join(', ')}"
    logger.error "Validation error in CreateObservationTool: #{error_message}"
    validation_error(error_message)
  rescue StandardError => e
    logger.error "Error in CreateObservationTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An internal server error occurred while creating the observation: #{e.message}")
  end
end
