# frozen_string_literal: true

module Projects
  # Async exports (UI-6 P5): pick roots, ExportJob writes the file in the background while the
  # progress page follows it over OperationProgressChannel, then download it. Files are removed
  # hourly (ExportJob.cleanup_old_exports in config/recurring.yml); an expired one answers 410.
  # The download path comes only from ExportJob.download_path(<a known export's UUID>).
  class ExportsController < BaseController
    self.nav_section = :exports
    PER_PAGE = 25
    MAX_ROOTS = ExportStrategy::ROOT_NODES_LIMIT
    ROOT_NAMES_KEPT = 20

    # GET /projects/exports(?q=): the root picker (Projects first, capped) and past exports
    def index
      load_index
    end

    # POST /projects/exports (ids[])
    def create
      roots = MemoryEntity.where(id: Array(params[:ids]).filter_map { |raw| EntityIdList.id(raw.to_s) }.first(MAX_ROOTS))
                          .order(:name).pluck(:id, :name)
      if roots.empty?
        @error = t("projects.exports.pick_one")
        load_index
        return render :index, status: :unprocessable_content
      end

      export_id = SecureRandom.uuid
      OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending", message: "Export queued",
                                details: { "entity_ids" => roots.map(&:first), "root_names" => roots.map(&:last).first(ROOT_NAMES_KEPT) })
      ExportJob.perform_later(export_id, roots.map(&:first))
      redirect_to projects_export_path(export_id)
    end

    # GET /projects/exports/:operation_id: progress, then the download link
    def show
      @export = find_operation!(params[:operation_id], "export")
      @file_available = ExportJob.export_exists?(@export.operation_id)
    end

    # GET /projects/exports/:operation_id/download (410 once the file has been cleaned up)
    def download
      export = find_operation!(params[:operation_id], "export")
      return render :expired, status: :gone unless export.status == "completed" && ExportJob.export_exists?(export.operation_id)

      send_file ExportJob.download_path(export.operation_id), type: "application/json", disposition: "attachment",
                                                              filename: "graph_mem_export_#{export.created_at.strftime('%Y%m%d_%H%M%S')}.json"
    end

    private

    def load_index
      @query = params[:q].to_s.strip.presence
      @roots = ExportStrategy.new.root_nodes(query: @query)
      @exports = OperationProgress.where(operation_type: "export").order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end
  end
end
