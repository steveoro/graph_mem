# frozen_string_literal: true

class CreateRelationTool < ApplicationTool
  def self.tool_name
    "create_relation"
  end

  description "Add one directed edge between two existing entities. Pass required `from_entity_id` " \
    "(integer or name; aliases `from_entity`, `from`), `to_entity_id` (integer or name; aliases `to_entity`, `to`), " \
    "and `relation_type` (string, canonicalized); optional `weight` (float >=0), `confidence` (float 0-1), " \
    "`properties` (hash). Do not use to create nodes; use `create_entity` instead. " \
    "Do not use to batch-create relations; use `bulk_update` instead. " \
    "Do not use to query existing 1-hop edges; use `find_relations` instead. " \
    "Do not use for a multi-hop neighborhood; use `traverse_graph` instead. " \
    "Do not use to remove an edge; use `delete_relation` instead."

  arguments do
    required(:from_entity_id).filled(:integer).description("The ID of the entity where the relation starts.")
    required(:to_entity_id).filled(:integer).description("The ID of the entity where the relation ends.")
    required(:relation_type).filled(:string).description("The type classification for the relationship (e.g., 'related_to', 'depends_on').")
    optional(:weight).maybe(:float).description("Optional non-negative relation weight.")
    optional(:confidence).maybe(:float).description("Optional confidence score from 0.0 to 1.0.")
    optional(:properties).hash.description("Optional structured relation properties.")
  end

  def call(from_entity_id:, to_entity_id:, relation_type:, weight: nil, confidence: nil, properties: {})
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
        relation_type: MemoryRelation.canonical_relation_type(relation_type),
        weight: weight,
        confidence: confidence,
        properties: properties
      )
      logger.info "Created relation: #{new_relation.inspect}"

      # Format output - return a single hash directly
      {
        relation_id: new_relation.id,
        from_entity_id: new_relation.from_entity_id,
        to_entity_id: new_relation.to_entity_id,
        relation_type: new_relation.relation_type,
        weight: new_relation.weight,
        confidence: new_relation.confidence,
        properties: new_relation.properties,
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
