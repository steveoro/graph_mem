# frozen_string_literal: true

class UpdateEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "update_entity"
  end

  description "Updates an existing entity in the graph memory database. Allows modification of name, entity_type, and aliases."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to update.")
    optional(:name).maybe(:string).description("The new name for the entity. If provided, must be unique.")
    optional(:entity_type).maybe(:string).description("The new type classification for the entity.")
    optional(:aliases).maybe(:string).description("The new pipe-separated string of aliases. This will replace existing aliases. Pass empty string to clear aliases.")
  end

  # Defines the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "integer", description: "The ID of the entity to update." },
        name: { type: [ "string", "null" ], description: "The new name for the entity. If provided, must be unique." },
        entity_type: { type: [ "string", "null" ], description: "The new type classification for the entity." },
        aliases: { type: [ "string", "null" ], description: "The new pipe-separated string of aliases. This will replace existing aliases. Pass empty string to clear aliases." }
      },
      required: [ "entity_id" ]
    }
  end

  def call(entity_id:, name: nil, entity_type: nil, aliases: nil)
    logger.info "Performing UpdateEntityTool for entity_id: #{entity_id}"

    # Check if at least one updatable attribute is provided
    unless name.present? || entity_type.present? || !aliases.nil? # !aliases.nil? allows empty string for clearing
      raise FastMcp::Tool::InvalidArgumentsError, "At least one attribute (name, entity_type, or aliases) must be provided for update."
    end

    entity = MemoryEntity.find_by(id: entity_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound, "Entity with ID #{entity_id} not found."
    end

    ActiveRecord::Base.transaction do
      entity.name = name if name.present?
      entity.entity_type = entity_type if entity_type.present?
      entity.aliases = aliases unless aliases.nil? # Update if aliases is provided (even if empty string)

      entity.save!
    end

    logger.info "Updated entity: #{entity.inspect}"

    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      aliases: entity.aliases,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      memory_observations_count: entity.memory_observations_count
    }
  rescue ActiveRecord::RecordInvalid => e
    error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
    logger.error "InvalidArguments in UpdateEntityTool: #{error_message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, error_message
  rescue McpGraphMemErrors::ResourceNotFound => e # Re-raise specific error
    raise e
  rescue StandardError => e
    logger.error "InternalServerError in UpdateEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in UpdateEntityTool: #{e.message}"
  end
end
