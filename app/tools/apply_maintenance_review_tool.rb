# frozen_string_literal: true

class ApplyMaintenanceReviewTool < ApplicationTool
  def self.tool_name
    "apply_maintenance_review"
  end

  description "Apply a queued maintenance-review row (merge, relationship proposal, orphan parent, or relation integrity). " \
    "Pass required `item_id` (string UUID); optional `report_type` (string, default compaction_review), " \
    "`dry_run` (bool, default false), `action_params` (hash). " \
    "Do not use without a queue item_id; use `list_maintenance_review` first. " \
    "Do not use to skip, ignore, or restore without applying; use `dismiss_maintenance_review` instead. " \
    "Do not use to merge two known entity ids outside the queue; use `merge_entities` instead."

  arguments do
    required(:item_id).filled(:string).description("Maintenance report row UUID.")
    optional(:report_type).filled(:string).description('Report type. Defaults to "compaction_review".')
    optional(:dry_run).filled(:bool).description("When true, validate and preview without applying.")
    optional(:action_params).hash.description("Optional overrides for merge/relation/orphan endpoints.")
  end

  def call(item_id:, report_type: "compaction_review", dry_run: false, action_params: {})
    row = CompactionReviewService.find_item(item_id, report_type: report_type)
    unless row
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Suggestion not found.",
        next_move: "Call `list_maintenance_review` to get a valid item_id, then retry `apply_maintenance_review`."
      )
    end

    if dry_run
      return {
        dry_run: true,
        item_id: item_id,
        kind: row.kind,
        payload: row.effective_payload,
        status: row.status
      }
    end

    result = CompactionReviewService.apply(item_id, action_params || {}, report_type: report_type)
    map_result!(result)
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "ApplyMaintenanceReviewTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def map_result!(result)
    return result if result[:success]

    message = result[:error].to_s
    if message.match?(/not found/i)
      raise McpGraphMemErrors::ResourceNotFound.new(
        message,
        next_move: "Call `list_maintenance_review` to get a valid item_id, then retry `apply_maintenance_review`."
      )
    elsif message.match?(/required|invalid|cannot|protected|different types|into itself|cycle/i)
      raise FastMcp::Tool::InvalidArgumentsError,
            "#{message}. Correct the review payload or `action_params` and retry `apply_maintenance_review`, " \
            "or call `dismiss_maintenance_review` to skip."
    else
      logger.error "ApplyMaintenanceReviewTool operation failed: #{message}"
      raise McpGraphMemErrors::OperationFailed.new(
        "The maintenance review could not be applied.",
        next_move: "Call `list_maintenance_review` to inspect the item, then retry `apply_maintenance_review` or `dismiss_maintenance_review`."
      )
    end
  end
end
