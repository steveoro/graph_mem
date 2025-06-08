# frozen_string_literal: true

class CreateRelationTool < ApplicationTool # Assuming ApplicationTool inherits from ActionTool::Base
  # Provide a custom tool name:
  def self.tool_name
    "create_relation"
  end

  description "Create a relationship between two existing entities."

  arguments do
    required(:from_entity_id).filled(:integer).description("The ID of the entity where the relation starts.")
    required(:to_entity_id).filled(:integer).description("The ID of the entity where the relation ends.")
    required(:relation_type).filled(:string).description("The type classification for the relationship (e.g., 'related_to', 'depends_on').")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: {
        from_entity_id: { type: "integer", description: "The ID of the entity where the relation starts." },
        to_entity_id: { type: "integer", description: "The ID of the entity where the relation ends." },
        relation_type: { type: "string", description: "The type classification for the relationship (e.g., 'related_to', 'depends_on')." }
      },
      required: [ "from_entity_id", "to_entity_id", "relation_type" ]
    }
  end

  # Output: Relation object

  def call(from_entity_id:, to_entity_id:, relation_type:) # Changed from perform
    logger.info "Performing CreateRelationTool with from_id: #{from_entity_id}, to_id: #{to_entity_id}, type: #{relation_type}"
    begin
      # Explicitly find entities to ensure they exist before creating the relation
      # This will raise ActiveRecord::RecordNotFound if an entity is not found,
      # which is then rescued below to raise a McpGraphMemErrors::ResourceNotFound.
      _from_entity = MemoryEntity.find(from_entity_id)
      _to_entity = MemoryEntity.find(to_entity_id)

      new_relation = MemoryRelation.create!(
        from_entity_id: from_entity_id,
        to_entity_id: to_entity_id,
        relation_type: relation_type
      )

      # Format output - return a single hash directly
      {
        relation_id: new_relation.id.to_s,
        from_entity_id: new_relation.from_entity_id,
        to_entity_id: new_relation.to_entity_id,
        relation_type: new_relation.relation_type,
        created_at: new_relation.created_at.iso8601,
        updated_at: new_relation.updated_at.iso8601
      }
    rescue ActiveRecord::RecordNotFound => e
      # This will catch if MemoryEntity.find fails for from_entity_id or to_entity_id
      error_message = "One or both entities not found: #{e.message}"
      logger.error "ResourceNotFound in CreateRelationTool: #{error_message}"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordInvalid => e
      # This catches other validation errors on MemoryRelation itself (e.g., invalid relation_type if validated)
      error_message = "Validation Failed for relation: #{e.record.errors.full_messages.join(', ')}"
      logger.error "InvalidArguments in CreateRelationTool: #{error_message} (was: #{e.message})"
      raise FastMcp::Tool::InvalidArgumentsError, error_message
    rescue StandardError => e
      logger.error "InternalServerError in CreateRelationTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in CreateRelationTool: #{e.message}"
    end
  end
end
