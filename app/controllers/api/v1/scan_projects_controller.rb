# frozen_string_literal: true

module Api
  module V1
    class ScanProjectsController < BaseController
      # POST /api/v1/scan
      def create
        project_root = params[:project_root].to_s.strip
        return render_error("project_root is required") if project_root.blank?
        return render_error("project_root is not a directory") unless File.directory?(File.expand_path(project_root))

        mode = params[:mode].to_s.downcase.presence || "initial"
        return render_error("mode must be initial, rescan, or validate") unless ScanProjectTool::MODES.include?(mode)

        scan_id = SecureRandom.uuid
        ProjectScanJob.perform_later(
          scan_id,
          File.expand_path(project_root),
          params[:project_name].to_s.presence,
          params[:aliases].to_s.presence,
          mode,
          params[:dry_run] == true || params[:dry_run].to_s.downcase == "true",
          Array(params[:file_globs])
        )

        render json: {
          scan_id: scan_id,
          status: "queued",
          project_root: File.expand_path(project_root),
          mode: mode,
          dry_run: params[:dry_run].to_s.downcase == "true"
        }
      end

      # GET /api/v1/scan/:id
      def show
        scan_id = params[:id].to_s
        operation = OperationProgress.find_by(operation_id: scan_id, operation_type: "project_scan")
        return render_error("Scan not found", status: :not_found) unless operation

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

        render json: {
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
      end
    end
  end
end
