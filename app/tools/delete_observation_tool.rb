# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_observation"
  end

  description "Delete a specific observation by ID."

  arguments do
    required(:observation_id).filled(:integer).description("The ID of the observation to delete.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: { observation_id: { type: "integer", description: "The ID of the observation to delete." } },
      required: [ "observation_id" ]
    }
  end

  # Output: Success message object

  def call(observation_id:)
    logger.info "Performing DeleteObservationTool with observation_id: #{observation_id}"

    begin
      # Find and destroy the observation
      observation = MemoryObservation.find(observation_id)
      observation_attributes = observation.attributes # Capture attributes before destroy
      observation.destroy!
      logger.info "Deleted observation with ID #{observation_attributes["id"]}"

      # Return the attributes of the deleted observation as a simple hash
      {
        observation_id: observation_attributes["id"],
        memory_entity_id: observation_attributes["memory_entity_id"],
        content: observation_attributes["content"],
        created_at: observation_attributes["created_at"].iso8601(3),
        updated_at: observation_attributes["updated_at"].iso8601(3),
        message: "Observation with ID=#{observation_id} deleted successfully."
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Observation with ID=#{observation_id} not found."
      logger.error "ResourceNotFound in DeleteObservationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordNotDestroyed => e
      error_message = "Failed to delete observation with ID=#{observation_id}: #{e.message}"
      logger.error "OperationFailed in DeleteObservationTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed, error_message
    rescue StandardError => e
      logger.error "InternalServerError in DeleteObservationTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in DeleteObservationTool: #{e.message}"
    end
  end
end
