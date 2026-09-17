# frozen_string_literal: true

class DismissMaintenanceReviewTool < ApplicationTool
  ALLOWED_ACTIONS = %w[dismiss ignore restore].freeze

  def self.tool_name
    "dismiss_maintenance_review"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Dismiss, ignore, or restore a maintenance-review queue row without applying the suggestion. " \
    "Pass required `item_id` (string UUID) and `action` (dismiss, ignore, or restore); optional " \
    "`report_type` (string, default compaction_review), `reason` (string). " \
    "Do not use to execute the suggestion; use `apply_maintenance_review` instead. " \
    "Do not use to look up a row; use `list_maintenance_review` instead. " \
    "Do not use to merge entities; use `graph_delete` instead."

  arguments do
    required(:item_id).filled(:string).description("Maintenance report row UUID.")
    required(:action).filled(:string).description("One of: dismiss, ignore, restore.")
    optional(:report_type).filled(:string).description('Report type. Defaults to "compaction_review".')
    optional(:reason).filled(:string).description("Optional dismissal reason.")
  end

  def call(item_id:, action:, report_type: "compaction_review", reason: nil)
    action = action.to_s
    unless ALLOWED_ACTIONS.include?(action)
      raise FastMcp::Tool::InvalidArgumentsError,
            "Invalid action '#{action}'. action must be one of: #{ALLOWED_ACTIONS.join(', ')}."
    end

    result = case action
    when "dismiss"
      CompactionReviewService.dismiss(item_id, reason: reason, report_type: report_type)
    when "ignore"
      CompactionReviewService.ignore(item_id, report_type: report_type)
    when "restore"
      CompactionReviewService.restore(item_id, report_type: report_type)
    end

    return result if result[:success]

    message = result[:error].to_s
    if message.match?(/not found/i)
      raise McpGraphMemErrors::ResourceNotFound.new(
        message,
        next_move: "Call `list_maintenance_review` to get a valid item_id, then retry `dismiss_maintenance_review`."
      )
    end

    logger.error "DismissMaintenanceReviewTool operation failed: #{message}"
    raise McpGraphMemErrors::OperationFailed.new(
      "The maintenance review could not be updated.",
      next_move: "Call `list_maintenance_review` to inspect the item, then retry `dismiss_maintenance_review`."
    )
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "DismissMaintenanceReviewTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
