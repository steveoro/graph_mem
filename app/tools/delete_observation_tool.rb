# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_observation"
  end

  description "Marks an observation obsolete by ID. The retained observation is excluded from reads and search by default."

  arguments do
    required(:observation_id).filled(:integer).description("The ID of the observation to delete.")
    optional(:reason).maybe(:string).description("Optional reason for marking the observation obsolete.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: {
        observation_id: { type: "integer", description: "The ID of the observation to delete." },
        reason: { type: "string", description: "Optional reason for marking the observation obsolete." }
      },
      required: [ "observation_id" ]
    }
  end

  # Output: Success message object

  def call(observation_id:, reason: nil)
    logger.info "Performing DeleteObservationTool with observation_id: #{observation_id}, reason: #{reason}"

    begin
      observation = MemoryObservation.find(observation_id)
      observation.mark_obsolete!(reason: reason)
      logger.info "Marked observation with ID #{observation.id} obsolete"

      MemoryObservationSerializer.call(
        observation,
        content_key: :observation_content,
        include_entity_id: true
      ).merge(message: "Observation with ID=#{observation_id} marked obsolete successfully.")
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Observation with ID=#{observation_id} not found."
      logger.error "ResourceNotFound in DeleteObservationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordInvalid => e
      error_message = "Failed to mark observation with ID=#{observation_id} obsolete: #{e.message}"
      logger.error "OperationFailed in DeleteObservationTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed, error_message
    rescue StandardError => e
      logger.error "InternalServerError in DeleteObservationTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in DeleteObservationTool: #{e.message}"
    end
  end
end
