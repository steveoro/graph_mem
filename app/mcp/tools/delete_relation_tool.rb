# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  description "Delete a specific relation by ID."

  property :relation_id,
           type: "integer",
           description: "The ID of the relation to delete.",
           required: true

  # Output: Success message object

  def perform
    logger.info "Performing DeleteRelationTool with relation_id: #{relation_id}"
    begin
      # Find and destroy the relation
      relation = MemoryRelation.find(relation_id)
      relation.destroy!

      # Return success message
      render(text: "Relation with ID=#{relation_id} deleted successfully.", mime_type: "text/plain")

    rescue ActiveRecord::RecordNotFound => e
      logger.error "Relation Not Found in DeleteRelationTool: ID=#{relation_id}"
      render(error: [ "Relation with ID=#{relation_id} not found." ])
    # No KeyError needed
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Relation in DeleteRelationTool: ID=#{relation_id}, Error: #{e.message}"
      render(error: [ "Failed to delete relation: #{e.message}" ])
    rescue => e
      logger.error "Unexpected error in DeleteRelationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
