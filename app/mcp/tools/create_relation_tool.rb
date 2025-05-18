# frozen_string_literal: true

class CreateRelationTool < ApplicationTool
  description "Create a relationship between two existing entities."

  property :from_entity_id,
           type: "integer",
           description: "The ID of the entity where the relation starts.",
           required: true

  property :to_entity_id,
           type: "integer",
           description: "The ID of the entity where the relation ends.",
           required: true

  property :relation_type,
           type: "string",
           description: "The type classification for the relationship (e.g., 'related_to', 'depends_on').",
           required: true

  # Output: Relation object

  def perform
    logger.info "Performing CreateRelationTool with from_id: #{from_entity_id}, to_id: #{to_entity_id}, type: #{relation_type}"
    begin
      new_relation = MemoryRelation.create!(
        from_entity_id: from_entity_id,
        to_entity_id: to_entity_id,
        relation_type: relation_type
      )

      # Format output
      relation_json = {
        id: new_relation.id,
        from_entity_id: new_relation.from_entity_id,
        to_entity_id: new_relation.to_entity_id,
        relation_type: new_relation.relation_type,
        created_at: new_relation.created_at.iso8601,
        updated_at: new_relation.updated_at.iso8601
      }
      render(text: relation_json.to_json, mime_type: "application/json")

    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateRelationTool: #{e.message}"
      if e.message.include?("must exist") # Specific check for foreign key validation
        render(error: [ "One or both entities not found or #{e.record.errors.full_messages.join(', ')}" ])
      else
        render(error: [ "Validation Failed: #{e.record.errors.full_messages.join(', ')}" ])
      end
    # No KeyError needed
    rescue => e
      logger.error "Unexpected error in CreateRelationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
