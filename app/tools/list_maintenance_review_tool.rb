# frozen_string_literal: true

class ListMaintenanceReviewTool < ApplicationTool
  PER_PAGE = CompactionReviewService::PER_PAGE

  def self.tool_name
    "list_maintenance_review"
  end

  description "List compaction review queue rows with optional status/kind filters and pagination."

  arguments do
    optional(:report_type).filled(:string).description('Report type. Defaults to "compaction_review".')
    optional(:status).filled(:string).description("Row status filter: active, dismissed, approved, ignored.")
    optional(:kind).filled(:string).description("Row kind filter, e.g. entity_merge or orphan_parent.")
    optional(:page).filled(:integer).description("Page number (1-based). Defaults to 1.")
  end

  def call(report_type: "compaction_review", status: "active", kind: nil, page: 1)
    page = [ page.to_i, 1 ].max
    rows = CompactionReviewService.items(report_type: report_type, status: status, kind: kind, page: page)

    {
      report_type: report_type,
      status: status,
      kind: kind,
      page: page,
      per_page: PER_PAGE,
      total_count: rows.total_count,
      total_pages: rows.total_pages,
      items: rows.map { |row| serialize_row(row) }
    }
  end

  private

  def serialize_row(row)
    {
      item_id: row.row_uuid,
      kind: row.kind,
      status: row.status,
      payload: row.effective_payload,
      signature: row.signature,
      created_at: row.created_at&.iso8601,
      updated_at: row.updated_at&.iso8601
    }
  end
end
