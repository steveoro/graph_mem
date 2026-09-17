# frozen_string_literal: true

class DeleteObservationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_observation"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Mark one observation obsolete so it is excluded from default reads and search; does not delete entities " \
    "or relations. Pass required `observation_id` (integer); optional `reason` (string). " \
    "Repeating on an inactive observation is safe. Do not use to replace a fact while retaining history; " \
    "use `graph_edit` with supersede true instead. Do not use to add a fact; use `graph_write` instead. " \
    "Do not use to destroy an entity; use `graph_delete` instead."

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
      GraphDeleteService.execute_one(
        "delete_observation",
        observation_id: observation_id,
        reason: reason
      )
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Observation with ID=#{observation_id} not found."
      logger.error "ResourceNotFound in DeleteObservationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `get_entities` with include_obsolete if needed to list observation ids, then retry `graph_delete`."
      )
    rescue ActiveRecord::RecordInvalid => e
      error_message = "Failed to mark observation with ID=#{observation_id} obsolete: #{e.message}"
      logger.error "OperationFailed in DeleteObservationTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed.new(
        error_message,
        category: "validation",
        next_move: "Call `get_entities` with include_obsolete if needed to inspect the observation, then retry `graph_delete`."
      )
    rescue StandardError => e
      raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }
      raise if e.is_a?(McpGraphMemErrors::Error)

      logger.error "InternalServerError in DeleteObservationTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
