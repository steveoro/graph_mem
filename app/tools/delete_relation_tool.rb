# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  description "Delete a specific relation by ID."

  arguments do
    required(:relation_id).filled(:integer).description("The ID of the relation to delete.")
  end

  # Output: Success message object

  def call(relation_id:)
    logger.info "Performing DeleteRelationTool with relation_id: #{relation_id}"
    begin
      # Find and destroy the relation
      relation = MemoryRelation.find(relation_id)
      relation.destroy!

      # Return success message - as a hash
      { message: "Relation with ID=#{relation_id} deleted successfully." }
    rescue ActiveRecord::RecordNotFound => e
      logger.error "Relation Not Found in DeleteRelationTool: ID=#{relation_id}"
      raise FastMcp::Errors::ResourceNotFound, "Relation with ID=#{relation_id} not found."
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Relation in DeleteRelationTool: ID=#{relation_id}, Error: #{e.message}"
      raise FastMcp::Errors::OperationFailed, "Failed to delete relation: #{e.message}"
    rescue => e
      logger.error "Unexpected error in DeleteRelationTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
