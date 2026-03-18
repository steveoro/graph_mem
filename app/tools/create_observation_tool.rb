# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  def self.tool_name
    "create_observation"
  end

  description "Creates new observations to existing entities in the knowledge graph. " \
    "Requires entity_id (integer) and text_content (string). " \
    "Also accepts entity name (string) instead of entity_id, and content/contents as aliases for text_content."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to add the observation to")
    required(:text_content).filled(:string).description("The textual content of the observation")
  end

  def call(entity_id:, text_content:)
    logger.info "Performing CreateObservationTool with entity_id: #{entity_id}, text_content: '#{text_content}'"
    begin
      entity = MemoryEntity.find(entity_id)

      new_observation = MemoryObservation.create!(memory_entity: entity, content: text_content)
      logger.info "Created observation: #{new_observation.inspect}"

      {
        observation_id: new_observation.id,
        memory_entity_id: new_observation.memory_entity_id,
        observation_content: new_observation.content,
        created_at: new_observation.created_at.iso8601,
        updated_at: new_observation.updated_at.iso8601
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in CreateObservationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordInvalid => e
      error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
      logger.error "InvalidArguments in CreateObservationTool: #{error_message} (was: #{e.message})"
      raise FastMcp::Tool::InvalidArgumentsError, error_message
    rescue StandardError => e
      logger.error "InternalServerError in CreateObservationTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in CreateObservationTool: #{e.message}"
    end
  end
end
