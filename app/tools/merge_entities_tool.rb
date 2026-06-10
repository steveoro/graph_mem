# frozen_string_literal: true

class MergeEntitiesTool < ApplicationTool
  def self.tool_name
    "merge_entities"
  end

  description "Merge a source entity into a target entity. Transfers observations, re-parents relations, " \
    "adds the source name to target aliases, and deletes the source entity."

  arguments do
    required(:source_entity_id).filled(:integer)
      .description("The entity to merge from (will be deleted).")
    required(:target_entity_id).filled(:integer)
      .description("The entity to merge into (will be kept).")
  end

  def call(source_entity_id:, target_entity_id:)
    result = NodeOperationsStrategy.new.merge_into(source_entity_id, target_entity_id)

    if result[:success]
      {
        status: "merged",
        message: result[:message],
        source_entity_id: source_entity_id,
        target_entity_id: target_entity_id
      }
    else
      raise McpGraphMemErrors::InternalServerError, result[:error]
    end
  rescue McpGraphMemErrors::InternalServerError
    raise
  rescue StandardError => e
    logger.error "MergeEntitiesTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end
