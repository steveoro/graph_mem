# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "create_observation"
  end

  description "Creates new observations to existing entities in the knowledge graph"

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to add the observation to")
    required(:content).filled(:string).description("The textual content of the observation")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "integer", description: "The ID of the entity to add the observation to" },
        content: { type: "string", description: "The textual content of the observation" }
      },
      required: [ "entity_id", "content" ]
    }
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
        observation_id: new_observation.id.to_s,
        memory_entity_id: new_observation.memory_entity_id,
        content: new_observation.content,
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
