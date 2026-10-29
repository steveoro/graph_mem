# frozen_string_literal: true

module Projects
  # Imports (UI-6 P4): upload a GraphMem export or a Graphify graph.json, review the matches,
  # execute (inside the request, Decision 3), and open any past import's report from the history.
  # Every upload error re-renders the form (422); nothing redirects to Home.
  #
  # :id is the upload's ImportSession id for show / execute / destroy, and the import's
  # OperationProgress id for report. Both are UUIDs, checked before any lookup.
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

    # POST /projects/imports (multipart: file, project_name)
    def create
      @upload = ImportFlow.upload(params[:file], project_name: params[:project_name])
      return render :new, status: :unprocessable_content if @upload.error

      session[:import_session_id] = @upload.session_id
      redirect_to projects_import_path(@upload.session_id)
    end

    # GET /projects/imports/:id: the review
    def show
      @matches = ImportSession.load_matches(@session_id)
      @stats = ImportSession.load_stats(@session_id) || {}
      @meta = ImportSession.load_meta(@session_id)
      @items = ImportReviewService.items(@matches, page: params[:page])
      # One more than the cap, so the hint shows only when something was cut.
      parents = ExportStrategy.new.root_nodes(limit: ExportStrategy::ROOT_NODES_LIMIT + 1)
      @parents_capped = parents.size > ExportStrategy::ROOT_NODES_LIMIT
      @available_parents = parents.first(ExportStrategy::ROOT_NODES_LIMIT)
    end

    # POST /projects/imports/:id/execute
    def execute
      operation = ImportFlow.execute(@session_id, params[:decisions])
      session.delete(:import_session_id)
      redirect_to report_projects_import_path(operation.operation_id)
    end

    # GET /projects/imports/:id/report
    def report
      @operation = find_operation!(params[:id], "import")
    end

    # DELETE /projects/imports/:id: cancel the review
    def destroy
      ImportSession.cleanup(@session_id)
      session.delete(:import_session_id)
      redirect_to projects_imports_path, notice: t("projects.imports.cancelled")
    end

    private

    def load_session
      raise ActiveRecord::RecordNotFound, "Import not found" unless uuid?(params[:id]) && ImportSession.exists?(params[:id])

      @session_id = params[:id]
    end
  end
end
