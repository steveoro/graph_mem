# frozen_string_literal: true

class ApplyMaintenanceReviewTool < ApplicationTool
  def self.tool_name
    "apply_maintenance_review"
  end

  description "Apply a maintenance review row (merge, relation, or orphan parent). Supports dry-run preview."

  arguments do
    required(:item_id).filled(:string).description("Maintenance report row UUID.")
    optional(:report_type).filled(:string).description('Report type. Defaults to "compaction_review".')
    optional(:dry_run).filled(:bool).description("When true, validate and preview without applying.")
    optional(:action_params).hash.description("Optional overrides for merge/relation/orphan endpoints.")
  end

  def call(item_id:, report_type: "compaction_review", dry_run: false, action_params: {})
    row = CompactionReviewService.find_item(item_id, report_type: report_type)
    raise McpGraphMemErrors::ResourceNotFound, "Suggestion not found" unless row

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
  end

  private

  def map_result!(result)
    return result if result[:success]

    message = result[:error].to_s
    if message.match?(/not found/i)
      raise McpGraphMemErrors::ResourceNotFound, message
    elsif message.match?(/required|invalid|cannot|protected|different types/i)
      raise FastMcp::Tool::InvalidArgumentsError, message
    else
      raise McpGraphMemErrors::OperationFailed, message
    end
  end
end
