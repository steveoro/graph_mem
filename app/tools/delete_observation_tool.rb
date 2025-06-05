# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'delete_observation'
  end

  description "Delete an observation from the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      observation_id: { type: "string", description: "The ID of the observation to delete." }
    },
    required: ["observation_id"]
  })

  # Output: Success message object

  def call(observation_id:)
    return validation_error("Observation ID cannot be blank") if observation_id.blank?

    observation = MemoryObservation.find_by(id: observation_id)
    return not_found_error("Observation", observation_id) unless observation

    observation.destroy!
    success_response({ message: "Observation deleted successfully", deleted_observation_id: observation_id })
  rescue StandardError => e
    error_response("Error deleting observation: #{e.message}")
  end
end
