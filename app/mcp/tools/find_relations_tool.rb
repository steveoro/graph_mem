# frozen_string_literal: true

class FindRelationsTool < ApplicationTool
  description "Find relations based on optional filtering criteria (from_entity_id, to_entity_id, relation_type)."

  property :from_entity_id,
           type: "integer",
           description: "Optional: Filter relations starting from this entity ID.",
           required: false

  property :to_entity_id,
           type: "integer",
           description: "Optional: Filter relations ending at this entity ID.",
           required: false

  property :relation_type,
           type: "string",
           description: "Optional: Filter relations by this type.",
           required: false

  # Output: Array of relation objects

  def perform
    logger.info "Performing FindRelationsTool with filters: from=#{from_entity_id}, to=#{to_entity_id}, type=#{relation_type}"
    begin
      # Start with all relations
      relations_query = MemoryRelation.all

      # Apply filters if provided
      relations_query = relations_query.where(from_entity_id: from_entity_id) if from_entity_id
      relations_query = relations_query.where(to_entity_id: to_entity_id) if to_entity_id
      relations_query = relations_query.where(relation_type: relation_type) if relation_type

      # Execute the query and get results
      matching_relations = relations_query.to_a

      # Format output
      result_hash = matching_relations.map do |relation|
        {
          id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type,
          created_at: relation.created_at.iso8601,
          updated_at: relation.updated_at.iso8601
        }
      end
      render(text: result_hash.to_json, mime_type: "application/json")

    # No KeyError needed
    rescue => e
      logger.error "Unexpected error in FindRelationsTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
