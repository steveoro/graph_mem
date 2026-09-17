# frozen_string_literal: true

class UpdateEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "update_entity"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Update metadata of an existing entity (not observations). Pass required `entity_id` (integer); " \
    "optional `name` (unique string), `entity_type` (canonicalized string), `aliases` (replaces existing; empty string clears), " \
    "`description` (empty string clears). Do not use to add or edit facts; use `graph_write` or `graph_edit` instead. " \
    "Do not use to create a node; use `graph_write` instead. Do not use to read; use `get_entities` instead. " \
    "Do not use to delete; use `graph_delete` instead. Do not use to combine two entities; use `graph_delete` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to update.")
    optional(:name).maybe(:string).description("The new name for the entity. If provided, must be unique.")
    optional(:entity_type).maybe(:string).description("The new type classification for the entity.")
    optional(:aliases).maybe(:string).description("The new pipe-separated string of aliases. This will replace existing aliases. Pass empty string to clear aliases.")
    optional(:description).maybe(:string).description("A short description of the entity. Pass empty string to clear.")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "integer", description: "The ID of the entity to update." },
        name: { type: [ "string", "null" ], description: "The new name for the entity. If provided, must be unique." },
        entity_type: { type: [ "string", "null" ], description: "The new type classification for the entity." },
        aliases: { type: [ "string", "null" ], description: "The new pipe-separated string of aliases. This will replace existing aliases. Pass empty string to clear aliases." },
        description: { type: [ "string", "null" ], description: "A short description of the entity. Pass empty string to clear." }
      },
      required: [ "entity_id" ]
    }
  end

  def call(entity_id:, name: nil, entity_type: nil, aliases: nil, description: nil)
    logger.info "Performing UpdateEntityTool for entity_id: #{entity_id}"
    GraphEditService.execute_one(
      "update_entity",
      {
        entity_id: entity_id,
        name: name,
        entity_type: entity_type,
        aliases: aliases,
        description: description
      }.compact
    )
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}. " \
      "Provide a unique name and valid entity_type, then retry `graph_edit`."
    logger.error "InvalidArguments in UpdateEntityTool: #{error_message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, error_message
  rescue McpGraphMemErrors::ResourceNotFound
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "UpdateEntityTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
