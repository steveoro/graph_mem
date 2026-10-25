# frozen_string_literal: true

module Api
  module V1
    class ScanProjectsController < BaseController
      # POST /api/v1/scan
      def create
        resolution = ScanRootPolicy.resolve(params[:project_root])
        unless resolution.ok?
          status = resolution.code == :denied ? :forbidden : :unprocessable_content
          return render_error(resolution.message, status: status, details: { code: resolution.code.to_s })
        end

        project_root = resolution.path
        file_globs = Array(params[:file_globs])
        if (bad_glob = ProjectScanFileFilter.new(project_root).invalid_glob(file_globs))
          return render_error("file_globs entry #{bad_glob.inspect} must be relative to project_root, without '..'",
                              details: { code: "invalid_file_globs" })
        end

        mode = params[:mode].to_s.downcase.presence || "initial"
        return render_error("mode must be initial, rescan, or validate") unless ScanProjectTool::MODES.include?(mode)

        scan_id = params[:scan_id].to_s.presence || SecureRandom.uuid
        ProjectScanJob.enqueue(
          scan_id: scan_id,
          project_root: project_root,
          project_name: params[:project_name].to_s.presence,
          aliases: params[:aliases].to_s.presence,
          mode: mode,
          dry_run: params[:dry_run] == true || params[:dry_run].to_s.downcase == "true",
          file_globs: file_globs
        )

        render json: {
          scan_id: scan_id,
          status: "queued",
          resumed: params[:scan_id].to_s.present?,
          project_root: project_root,
          warnings: resolution.warnings.map(&:to_s),
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
