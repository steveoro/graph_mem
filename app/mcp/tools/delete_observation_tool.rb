# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  description "Delete a specific observation by ID."

  property :observation_id,
           type: "integer",
           description: "The ID of the observation to delete.",
           required: true

  # Output: Success message object

  def perform
    logger.info "Performing DeleteObservationTool with observation_id: #{observation_id}"
    begin
      # Find and destroy the observation
      observation = MemoryObservation.find(observation_id)
      observation.destroy!

      # Return success message
      render(text: "Observation with ID=#{observation_id} deleted successfully.", mime_type: "text/plain")

    rescue ActiveRecord::RecordNotFound => e
      logger.error "Observation Not Found in DeleteObservationTool: ID=#{observation_id}"
      render(error: [ "Observation with ID=#{observation_id} not found." ])
    # No KeyError needed
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Observation in DeleteObservationTool: ID=#{observation_id}, Error: #{e.message}"
      render(error: [ "Failed to delete observation: #{e.message}" ])
    rescue => e
      logger.error "Unexpected error in DeleteObservationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
