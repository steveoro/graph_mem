# frozen_string_literal: true

class CreateRelationTool < ApplicationTool
  def self.tool_name
    'create_relation'
  end

  description "Create a new relation between two entities in the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      from_entity_id: {
        type: "string",
        description: "The ID of the source entity."
      },
      to_entity_id: {
        type: "string",
        description: "The ID of the target entity."
      },
      relation_type: {
        type: "string",
        description: "The type of relation (e.g., 'depends_on', 'related_to')."
      }
    },
    required: ["from_entity_id", "to_entity_id", "relation_type"]
  })

  def call(from_entity_id:, to_entity_id:, relation_type:)
    logger.info "Creating relation: #{from_entity_id} -[#{relation_type}]-> #{to_entity_id}"

    # Validate inputs
    return validation_error("From entity ID cannot be blank") if from_entity_id.blank?
    return validation_error("To entity ID cannot be blank") if to_entity_id.blank?
    return validation_error("Relation type cannot be blank") if relation_type.blank?

    # Find entities
    from_entity = MemoryEntity.find_by(id: from_entity_id)
    return not_found_error("From entity", from_entity_id) unless from_entity

    to_entity = MemoryEntity.find_by(id: to_entity_id)
    return not_found_error("To entity", to_entity_id) unless to_entity

    # Create relation
    relation = MemoryRelation.create!(
      from_entity: from_entity,
      to_entity: to_entity,
      relation_type: relation_type
    )

    result = {
      relation_id: relation.id.to_s,
      from_entity_id: from_entity.id.to_s,
      from_entity_name: from_entity.name,
      to_entity_id: to_entity.id.to_s,
      to_entity_name: to_entity.name,
      relation_type: relation.relation_type,
      created_at: relation.created_at.iso8601
    }

    success_response(result)
  rescue ActiveRecord::RecordInvalid => e
    validation_error("Failed to create relation: #{e.record.errors.full_messages.join(', ')}")
  rescue StandardError => e
    logger.error "Error in CreateRelationTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An error occurred while creating the relation: #{e.message}")
  end
end
