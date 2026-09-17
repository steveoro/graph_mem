# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  DEDUP_DISTANCE_THRESHOLD = 0.25

  def self.tool_name
    "create_entity"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Create a single new entity node. Pass required `name` (string) and `entity_type` (string); " \
    "optional `observations` (array of strings), `aliases` (pipe-separated string), `description` (string). " \
    "Alias `entityType` maps to `entity_type`. Types are canonicalized; cosine distance < 0.25 returns a warning " \
    "instead of creating. Do not use until you have searched for an existing node; use `search` first. " \
    "Do not use to add facts to a known entity; use `graph_write` instead. " \
    "Do not use to change metadata on an existing node; use `graph_edit` instead. " \
    "Do not use for an atomic batch of up to 50 creates; use `graph_write` instead."

  arguments do
    required(:name).filled(:string).description("The unique name for the new entity.")
    required(:entity_type).filled(:string).description("The type classification for the new entity (e.g., 'Project', 'Task', 'Issue').")
    optional(:observations).array(:string).description("Optional list of initial observation strings associated with the entity.")
    optional(:aliases).maybe(:string).description("Optional pipe-separated string of alternative names for the entity.")
    optional(:description).maybe(:string).description("Optional short description of the entity.")
  end

  def call(name:, entity_type:, observations: [], aliases: nil, description: nil)
    logger.info "Performing CreateEntityTool with name: #{name}, type: #{entity_type}"
    service_result = GraphWriteService.execute_one(
      "create_entity",
      {
        name: name,
        entity_type: entity_type,
        observations: observations,
        aliases: aliases,
        description: description
      },
      logger: logger
    )
    if service_result[:status] == "possible_duplicate"
      candidate = service_result[:candidates].first
      return {
        warning: "A similar entity already exists. Use update_entity or create_observation to add information to it instead of creating a duplicate.",
        existing_entity: {
          entity_id: candidate[:entity_id],
          name: candidate[:name],
          entity_type: candidate[:entity_type],
          description: candidate[:description],
          aliases: candidate[:aliases],
          similarity_distance: candidate[:similarity_distance]
        }
      }
    end

    service_result
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}. " \
      "Provide a unique non-blank name and entity_type; call `search` if this name may already exist."
    logger.error "InvalidArguments in CreateEntityTool: #{error_message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, error_message
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue FastMcp::Tool::InvalidArgumentsError => e
    raise FastMcp::Tool::InvalidArgumentsError, "Validation Failed: #{e.message}"
  rescue McpGraphMemErrors::Error
    raise
  rescue StandardError => e
    logger.error "CreateEntityTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
