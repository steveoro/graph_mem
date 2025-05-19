# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  description "Creates new observations to existing entities in the knowledge graph"

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to add the observation to")
    required(:content).filled(:string).description("The textual content of the observation")
  end

  def call(entity_id:, content:)
    logger.info "Performing CreateObservationTool with entity_id: #{entity_id}, content: '#{content}'"
    begin
      entity = MemoryEntity.find(entity_id)

      new_observation = MemoryObservation.create!(
        memory_entity: entity,
        content: content
      )

      {
        id: new_observation.id,
        memory_entity_id: new_observation.memory_entity_id,
        content: new_observation.content,
        created_at: new_observation.created_at.iso8601,
        updated_at: new_observation.updated_at.iso8601
      }
    rescue ActiveRecord::RecordNotFound => e
      logger.error "Entity Not Found in CreateObservationTool: ID=#{entity_id} - #{e.message}"
      raise FastMcp::Errors::ResourceNotFound, "Entity with ID #{entity_id} not found."
    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateObservationTool: #{e.message}"
      error_messages = e.record.errors.full_messages.join(", ")
      raise FastMcp::Errors::InvalidParameters, "Validation Failed: #{error_messages}"
    rescue => e
      logger.error "Unexpected error in CreateObservationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
