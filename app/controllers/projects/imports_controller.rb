# frozen_string_literal: true

module Projects
  # Imports (UI-6 P4): upload a graph_mem-sql script, which is validated and dry-run (SqlImport::Flow), see
  # its preview, execute it, and open any past import's report from the history (the rake imports and
  # the JSON imports from before 1.94.0 included); the report can start full maintenance. JSON imports were
  # retired in 1.94.0: a JSON file is refused (ImportFlow). Every upload error re-renders the form (422);
  # nothing redirects to Home.
  #
  # :id is the upload's ImportSession id for show / execute / destroy, and the import's
  # OperationProgress id for report and maintenance. Both are UUIDs, checked before any lookup.
  class ImportsController < BaseController
    self.nav_section = :imports
    PER_PAGE = 25

    before_action :load_session, only: %i[show execute destroy]

    # GET /projects/imports: every import, the rake ones included, newest first
    def index
      @imports = OperationProgress.where(operation_type: "import").order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end

    # GET /projects/imports/new
    def new; end

    # POST /projects/imports (multipart: file)
    def create
      @upload = ImportFlow.upload(params[:file])
      return render :new, status: :unprocessable_content if @upload.error

      session[:import_session_id] = @upload.session_id
      redirect_to projects_import_path(@upload.session_id)
    end

    # GET /projects/imports/:id: the script's dry-run preview
    def show
      show_preview
    end

    # POST /projects/imports/:id/execute (full_maintenance=1 to run all scheduled jobs after it)
    #
    # A refusal (before the commit) re-renders the preview: nothing was written. After the commit the
    # session is gone and the report opens, saying what didn't happen when the record couldn't be completed.
    def execute
      operation = SqlImport::Flow.execute(@session_id, full_maintenance: params[:full_maintenance] == "1")
      session.delete(:import_session_id)
      redirect_to report_projects_import_path(operation.operation_id)
    rescue SqlImport::Flow::FinishFailed => e
      session.delete(:import_session_id)
      redirect_to report_projects_import_path(e.operation_id),
                  alert: t("projects.imports.sql.not_finished", operation_id: e.operation_id, error: e.message)
    rescue *SqlImport::Flow::REFUSALS => e
      show_preview(error: t("projects.imports.sql.not_run", reason: SqlImport::Flow.refusal_reason(e)), status: :unprocessable_content)
    end

    # GET /projects/imports/:id/report
    def report
      @operation = find_operation!(params[:id], "import")
    end

    # POST /projects/imports/:id/maintenance: an SQL import report's "Run full maintenance now"
    def maintenance
      operation = find_operation!(params[:id], "import")
      raise ActiveRecord::RecordNotFound, "Not an SQL import" unless operation.details.to_h["format"] == "sql"
      return redirect_to(report_projects_import_path(operation.operation_id)) unless params[:full_maintenance] == "1"

      outcome = SqlImport::FollowUp.request_full_maintenance!(operation)
      redirect_to report_projects_import_path(operation.operation_id), notice: t("projects.imports.sql.full_maintenance.#{outcome}")
    end

    # DELETE /projects/imports/:id: cancel the preview
    def destroy
      ImportSession.cleanup(@session_id)
      session.delete(:import_session_id)
      redirect_to projects_imports_path, notice: t("projects.imports.cancelled")
    end

    private

    def show_preview(error: nil, status: :ok)
      @preview = ImportSession.load_preview(@session_id) || {}
      @meta = ImportSession.load_meta(@session_id)
      @error = error
      render :sql_preview, status: status
    end

    def load_session
      raise ActiveRecord::RecordNotFound, "Import not found" unless uuid?(params[:id]) && ImportSession.exists?(params[:id])

      @session_id = params[:id]
    end
  end
end
