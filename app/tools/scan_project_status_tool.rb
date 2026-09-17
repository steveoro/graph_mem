# frozen_string_literal: true

class ScanProjectStatusTool < ApplicationTool
  def self.tool_name
    "scan_project_status"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Poll one asynchronous project scan for status, phase, progress, counters, fallback flags, and " \
    "scan_review items. Pass required `scan_id` (string from `scan_project`). " \
    "Do not use to start or resume a scan; use `scan_project` instead. " \
    "Do not use for compaction-job status; use `dream_state_status` instead. " \
    "Do not use for stored scan_review documents; use `get_maintenance_reports` instead."

  arguments do
    required(:scan_id).filled(:string).description("The scan_id returned by scan_project.")
  end

  def call(scan_id:)
    operation = OperationProgress.find_by(operation_id: scan_id.to_s, operation_type: "project_scan")
    unless operation
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Scan with scan_id=#{scan_id} not found.",
        next_move: "Call `scan_project` to start a scan, then retry `scan_project_status` with that scan_id."
      )
    end

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
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error
    raise
  rescue StandardError => e
    logger.error "ScanProjectStatusTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
