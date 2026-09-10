# frozen_string_literal: true

class DismissMaintenanceReviewTool < ApplicationTool
  ALLOWED_ACTIONS = %w[dismiss ignore restore].freeze

  def self.tool_name
    "dismiss_maintenance_review"
  end

  description "Dismiss, ignore, or restore a maintenance-review queue row without applying the suggestion. " \
    "Pass required `item_id` (string UUID) and `action` (dismiss, ignore, or restore); optional " \
    "`report_type` (string, default compaction_review), `reason` (string). " \
    "Do not use to execute the suggestion; use `apply_maintenance_review` instead. " \
    "Do not use to look up a row; use `list_maintenance_review` instead. " \
    "Do not use to merge entities; use `merge_entities` instead."

  arguments do
    required(:item_id).filled(:string).description("Maintenance report row UUID.")
    required(:action).filled(:string).description("One of: dismiss, ignore, restore.")
    optional(:report_type).filled(:string).description('Report type. Defaults to "compaction_review".')
    optional(:reason).filled(:string).description("Optional dismissal reason.")
  end

  def call(item_id:, action:, report_type: "compaction_review", reason: nil)
    action = action.to_s
    unless ALLOWED_ACTIONS.include?(action)
      raise FastMcp::Tool::InvalidArgumentsError, "Invalid action: #{action}"
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

    raise McpGraphMemErrors::ResourceNotFound, result[:error]
  end
end
