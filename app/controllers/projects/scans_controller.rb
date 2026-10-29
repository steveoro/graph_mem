# frozen_string_literal: true

module Projects
  # Project scans (UI-6 P3): the history, one form for a normal or guided scan with a live path
  # check, and a detail page per scan. Starting a scan goes through ProjectScanLauncher, so a
  # path ScanRootPolicy refuses re-renders the form (422) and never enqueues a job.
  class ScansController < BaseController
    self.nav_section = :scans
    PER_PAGE = 25
    TYPES = ProjectsOverview::SCAN_TYPES
    FIELDS = %i[project_root project_name aliases mode file_globs dry_run guided].freeze

    # GET /projects/scans
    def index
      @scans = OperationProgress.where(operation_type: TYPES).order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end

    # GET /projects/scans/new(?project_root=)
    def new
      @values = { project_root: params[:project_root].to_s.presence }.compact
      @path_result = ScanRootPolicy.resolve(@values[:project_root]) if @values[:project_root]
    end

    # POST /projects/scans
    def create
      @values = params.permit(*FIELDS, depths: []).to_h.symbolize_keys
      result = ProjectScanLauncher.call(@values)
      return render_form_error(result.error) unless result.ok?

      redirect_to projects_scan_path(result.operation_id), notice: t("projects.scans.queued", path: result.path) + result.warnings
    rescue StandardError => e
      Rails.logger.error "Project scan trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render_form_error(t("projects.scans.queue_failed", error: e.message))
    end

    # GET /projects/scans/:operation_id (404 for anything but a scan's operation id)
    def show
      @scan = find_operation!(params[:operation_id], TYPES)
      @project_id = @scan.details&.dig("project_entity_id")
      @review_groups = scan_review_groups(@project_id)
    end

    # GET /projects/scans/check_path?path= (Turbo Frame "scan-path-check"): what ScanRootPolicy
    # would do with the path, without queueing anything. Settings › Project scans shows the same partial.
    def check_path
      result = params[:path].present? ? ScanRootPolicy.resolve(params[:path].to_s) : nil
      render partial: "projects/scans/path_check", locals: { result: result }
    end

    private

    def render_form_error(message)
      @error = message
      @path_result = ScanRootPolicy.resolve(@values[:project_root]) if @values[:project_root].present?
      render :new, status: :unprocessable_content
    end

    def scan_review_groups(project_id)
      return 0 if project_id.blank?

      MaintenanceReportRow.active.where(report_type: "scan_review", project_id: project_id).distinct.count(Arel.sql(ReviewDigest::GROUP_SQL))
    end
  end
end
