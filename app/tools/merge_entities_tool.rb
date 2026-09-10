# frozen_string_literal: true

class MergeEntitiesTool < ApplicationTool
  def self.tool_name
    "merge_entities"
  end

  description "Merge a source entity into a target: transfer observations, re-parent relations, add the source name " \
    "to target aliases, then delete the source. Pass required `source_entity_id` and `target_entity_id` (integers). " \
    "Do not use to find merge candidates; use `suggest_merges` instead. " \
    "Do not use to apply a queued review by item_id; use `apply_maintenance_review` instead. " \
    "Do not use to destroy an entity without transferring knowledge; use `delete_entity` instead."

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
      raise map_merge_error(result[:error])
    end
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "MergeEntitiesTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def map_merge_error(message)
    text = message.to_s
    if text.match?(/not found/i)
      return McpGraphMemErrors::ResourceNotFound.new(
        text,
        next_move: "Call `search_entities` to find valid entity ids, then retry `merge_entities`."
      )
    end

    if text.match?(/into itself/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Pass two different entity ids, or use `delete_entity` if you meant to remove that node."
      )
    end

    if text.match?(/Project root|protected/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Do not call `merge_entities` or `delete_entity` on a Project; " \
        "use `update_entity` or `create_observation` on the existing Project instead."
      )
    end

    if text.match?(/different types/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Merge only same-type entities, or use `delete_entity` if one should be removed instead of merged."
      )
    end

    if text.match?(/Cannot merge|cycle/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Choose a different source and target, or use `delete_entity` if you meant to remove a node."
      )
    end

    logger.error "MergeEntitiesTool operation failed: #{text}"
    McpGraphMemErrors::OperationFailed.new(
      "The merge could not be completed.",
      next_move: "Call `suggest_merges` or `get_entity` to inspect the pair, then retry `merge_entities` or escalate."
    )
  end
end
