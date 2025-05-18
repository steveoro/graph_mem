# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  tool_name "create_observations"
  description "Creates new observations to existing entities in the knowledge graph"

  property :entity_id,
           type: "integer",
           description: "The ID of the entity to add the observation to",
           required: true

  property :content,
           type: "string",
           description: "The textual content of the observation",
           required: true

  def perform
    logger.info "Performing CreateObservationTool with entity_id: #{entity_id}, content: '#{content}'"
    begin
      # Find the entity first
      entity = MemoryEntity.find(entity_id)

      # Create the observation associated with the entity
      new_observation = MemoryObservation.create!(
        memory_entity: entity,
        content: content
      )

      # Format output
      result_hash = {
        id: new_observation.id,
        memory_entity_id: new_observation.memory_entity_id,
        content: new_observation.content,
        created_at: new_observation.created_at.iso8601,
        updated_at: new_observation.updated_at.iso8601
      }
      render(text: result_hash.to_json, mime_type: "application/json")

    rescue ActiveRecord::RecordNotFound => e
      logger.error "Entity Not Found in CreateObservationTool: ID=#{entity_id}"
      render(error: [ "Entity with ID=#{entity_id} not found." ])
    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateObservationTool: #{e.message}"
      render(error: [ "Validation Failed: #{e.record.errors.full_messages.join(', ')}" ])
    # No KeyError needed
    rescue => e
      logger.error "Unexpected error in CreateObservationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
