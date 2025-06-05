# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'delete_relation'
  end

  description "Delete a relation from the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      relation_id: { type: "string", description: "The ID of the relation to delete." }
    },
    required: ["relation_id"]
  })

  # Output: Success message object

  def call(relation_id:)
    return validation_error("Relation ID cannot be blank") if relation_id.blank?

    relation = MemoryRelation.find_by(id: relation_id)
    return not_found_error("Relation", relation_id) unless relation

    relation.destroy!
    success_response({ message: "Relation deleted successfully", deleted_relation_id: relation_id })
  rescue StandardError => e
    error_response("Error deleting relation: #{e.message}")
  end
end
