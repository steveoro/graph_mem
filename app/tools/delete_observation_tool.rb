# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  description "Delete a specific observation by ID."

  arguments do
    required(:observation_id).filled(:integer).description("The ID of the observation to delete.")
  end

  # Output: Success message object

  def call(observation_id:)
    logger.info "Performing DeleteObservationTool with observation_id: #{observation_id}"
    begin
      # Find and destroy the observation
      observation = MemoryObservation.find(observation_id)
      observation.destroy!

      # Return success message - as a hash
      { message: "Observation with ID=#{observation_id} deleted successfully." }
    rescue ActiveRecord::RecordNotFound => e
      logger.error "Observation Not Found in DeleteObservationTool: ID=#{observation_id}"
      raise FastMcp::Errors::ResourceNotFound, "Observation with ID=#{observation_id} not found."
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Observation in DeleteObservationTool: ID=#{observation_id}, Error: #{e.message}"
      raise FastMcp::Errors::OperationFailed, "Failed to delete observation: #{e.message}"
    rescue => e
      logger.error "Unexpected error in DeleteObservationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
