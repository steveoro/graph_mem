# frozen_string_literal: true

class GetMaintenanceReportsTool < ApplicationTool
  DEFAULT_LIMIT = 5
  MAX_LIMIT = 30

  def self.tool_name
    "get_maintenance_reports"
  end

  description "Read stored maintenance report documents, not paginated review rows. Pass optional `report_type` " \
    "(orphans, duplicates, compaction_review, embedding_maintenance, contradictions, or scan_review; omit for the " \
    "latest of each type) and `limit` (integer, default 5, max 30). " \
    "Do not use for paginated item_id rows; use `list_maintenance_review` instead. " \
    "Do not use to apply or dismiss a row; use `apply_maintenance_review` or `dismiss_maintenance_review` instead. " \
    "Do not use for live compaction job status; use `dream_state_status` instead. " \
    "Do not use for a live duplicate scan; use `suggest_merges` instead."

  arguments do
    optional(:report_type).maybe(:string)
      .description("Filter to one type: orphans, duplicates, or compaction_review. Omit for the latest of each type.")
    optional(:limit).filled(:integer)
      .description("Maximum number of reports to return. Default: #{DEFAULT_LIMIT}, max: #{MAX_LIMIT}.")
  end

  def self.input_schema_to_json
    {
      type: "object",
      properties: {
        report_type: {
          type: [ "string", "null" ],
          enum: MaintenanceReport::REPORT_TYPES + [ nil ],
          description: "Filter to one type: #{MaintenanceReport::REPORT_TYPES.join(', ')}. Omit for the latest of each type."
        },
        limit: { type: "integer", description: "Max reports to return. Default: #{DEFAULT_LIMIT}, max: #{MAX_LIMIT}." }
      },
      required: []
    }
  end

  def call(report_type: nil, limit: nil)
    effective_limit = [ (limit || DEFAULT_LIMIT).to_i, MAX_LIMIT ].min
    effective_limit = DEFAULT_LIMIT if effective_limit <= 0

    if report_type.present?
      unless MaintenanceReport::REPORT_TYPES.include?(report_type)
        raise FastMcp::Tool::InvalidArgumentsError,
              "Unknown report_type '#{report_type}'. Valid types: #{MaintenanceReport::REPORT_TYPES.join(', ')}. " \
              "Retry `get_maintenance_reports` with one of those types, or call `list_maintenance_review` for paginated review rows."
      end

      reports = MaintenanceReport.by_type(report_type).recent.limit(effective_limit)
    else
      # Latest report of each type
      reports = MaintenanceReport::REPORT_TYPES.filter_map do |type|
        MaintenanceReport.by_type(type).recent.first
      end
    end

    {
      reports: reports.map { |report| serialize(report) },
      total: reports.size
    }
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "GetMaintenanceReportsTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def serialize(report)
    {
      id: report.id,
      report_type: report.report_type,
      created_at: report.created_at.iso8601,
      data: report.data,
      rows: report.maintenance_report_rows.map do |row|
        {
          id: row.id,
          row_uuid: row.row_uuid,
          kind: row.kind,
          status: row.status,
          payload: row.payload,
          edited_payload: row.edited_payload,
          signature: row.signature,
          created_at: row.created_at.iso8601
        }
      end
    }
  end
end
