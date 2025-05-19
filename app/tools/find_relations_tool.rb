# frozen_string_literal: true

class FindRelationsTool < ApplicationTool
  description "Find relations based on optional filtering criteria (from_entity_id, to_entity_id, relation_type)."

  arguments do
    optional(:from_entity_id).filled(:integer).description("Optional: Filter relations starting from this entity ID.")
    optional(:to_entity_id).filled(:integer).description("Optional: Filter relations ending at this entity ID.")
    optional(:relation_type).filled(:string).description("Optional: Filter relations by this type.")
  end

  # Output: Array of relation objects

  def call(from_entity_id: nil, to_entity_id: nil, relation_type: nil)
    logger.info "Performing FindRelationsTool with filters: from=#{from_entity_id}, to=#{to_entity_id}, type=#{relation_type}"
    begin
      # Start with all relations
      relations_query = MemoryRelation.all

      # Apply filters if provided
      relations_query = relations_query.where(from_entity_id: from_entity_id) if from_entity_id.present?
      relations_query = relations_query.where(to_entity_id: to_entity_id) if to_entity_id.present?
      relations_query = relations_query.where(relation_type: relation_type) if relation_type.present?

      # Execute the query and get results
      matching_relations = relations_query.to_a

      # Format output - return array of hashes directly
      matching_relations.map do |relation|
        {
          id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type,
          created_at: relation.created_at.iso8601,
          updated_at: relation.updated_at.iso8601
        }
      end
    rescue => e
      logger.error "Unexpected error in FindRelationsTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
