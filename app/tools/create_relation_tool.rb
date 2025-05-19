# frozen_string_literal: true

class CreateRelationTool < ApplicationTool # Assuming ApplicationTool inherits from ActionTool::Base
  description "Create a relationship between two existing entities."

  arguments do
    required(:from_entity_id).filled(:integer).description("The ID of the entity where the relation starts.")
    required(:to_entity_id).filled(:integer).description("The ID of the entity where the relation ends.")
    required(:relation_type).filled(:string).description("The type classification for the relationship (e.g., 'related_to', 'depends_on').")
  end

  # Output: Relation object

  def call(from_entity_id:, to_entity_id:, relation_type:) # Changed from perform
    logger.info "Performing CreateRelationTool with from_id: #{from_entity_id}, to_id: #{to_entity_id}, type: #{relation_type}"
    begin
      new_relation = MemoryRelation.create!(
        from_entity_id: from_entity_id,
        to_entity_id: to_entity_id,
        relation_type: relation_type
      )

      # Format output - return hash directly
      {
        id: new_relation.id,
        from_entity_id: new_relation.from_entity_id,
        to_entity_id: new_relation.to_entity_id,
        relation_type: new_relation.relation_type,
        created_at: new_relation.created_at.iso8601,
        updated_at: new_relation.updated_at.iso8601
      }
    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateRelationTool: #{e.message}"
      error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
      # Check if the error is due to non-existent entities (based on your original logic)
      if e.message.downcase.include?("must exist") || e.record.errors.any? { |err| err.attribute == :from_entity || err.attribute == :to_entity }
        # It's better to pre-fetch entities and raise ResourceNotFound if they don't exist.
        # However, sticking to translating existing error handling for now.
        # Consider changing this to a more specific FastMcp::Errors::ResourceNotFound
        # if from_entity or to_entity are explicitly checked before create!
        raise FastMcp::Errors::InvalidParameters, "One or both entities not found, or other validation error: #{e.record.errors.full_messages.join(', ')}"
      else
        raise FastMcp::Errors::InvalidParameters, error_message
      end
    rescue => e # No KeyError needed
      logger.error "Unexpected error in CreateRelationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
