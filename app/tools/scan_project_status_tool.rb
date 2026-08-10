# frozen_string_literal: true

class ScanProjectStatusTool < ApplicationTool
  def self.tool_name
    "scan_project_status"
  end

  description "Return the status of an asynchronous project scan. " \
    "Includes progress, counters, fallback flags, and any scan_review items queued for operator approval."

  arguments do
    required(:scan_id).filled(:string).description("The scan_id returned by scan_project.")
  end

  def call(scan_id:)
    operation = OperationProgress.find_by(operation_id: scan_id.to_s, operation_type: "project_scan")
    return { scan_id: scan_id, status: "not_found" } unless operation

    report = MaintenanceReport.by_type("scan_review").recent.first
    review_items = if report && operation.status == "completed"
      report.maintenance_report_rows.active.map do |row|
        {
          item_id: row.row_uuid,
          kind: row.kind,
          payload: row.effective_payload
        }
      end
    else
      []
    end

    {
      scan_id: scan_id,
      status: operation.status,
      phase: operation.phase,
      message: operation.message,
      progress: {
        current: operation.current_count,
        total: operation.total_count,
        percentage: operation.percentage
      },
      counters: operation.counters || {},
      details: operation.details || {},
      fallback: operation.details&.dig("fallback"),
      fallback_reason: operation.details&.dig("fallback_reason"),
      scan_review_items: review_items,
      started_at: operation.started_at&.iso8601,
      finished_at: operation.finished_at&.iso8601,
      error: operation.error_message
    }.compact
  rescue StandardError => e
    logger.error "ScanProjectStatusTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "Failed to retrieve scan status: #{e.message}"
  end
end
