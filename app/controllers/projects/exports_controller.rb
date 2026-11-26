# frozen_string_literal: true

module Projects
  # Async exports (UI-6 P5): pick roots, ExportJob writes a graph_mem-sql script in the background while
  # the progress page follows it over OperationProgressChannel, then download it. Files are removed hourly
  # (ExportJob.cleanup_old_exports in config/recurring.yml); an expired one answers 410. The download path
  # comes only from ExportJob.download_path(<a known export's UUID>).
  #
  # The JSON export was retired in 1.94.0. A row from before then may be one (its details say "json", or
  # name no format: rows made before the format choice were JSON): the history and its page show it as
  # retired, and its download answers 410.
  #
  # The script is sent as application/sql (RFC 6922, the registered type), always as an attachment, so
  # a browser saves it instead of rendering it; plain text would be shown inline by some.
  class ExportsController < BaseController
    self.nav_section = :exports
    PER_PAGE = 25
    MAX_ROOTS = SqlExport::Roots::LIMIT
    helper_method :export_format
    ROOT_NAMES_KEPT = 20
    RETIRED_FORMAT = "json"

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
                                details: { "entity_ids" => roots.map(&:first), "root_names" => roots.map(&:last).first(ROOT_NAMES_KEPT),
                                           "format" => ExportJob::FORMAT })
      ExportJob.perform_later(export_id, roots.map(&:first))
      redirect_to projects_export_path(export_id)
    end

    # GET /projects/exports/:operation_id: progress, then the download link
    def show
      @export = find_operation!(params[:operation_id], "export")
      @file_available = !retired?(@export) && ExportJob.export_exists?(@export.operation_id)
    end

    # GET /projects/exports/:operation_id/download (410 once the file has been cleaned up, or for a retired JSON export)
    def download
      export = find_operation!(params[:operation_id], "export")
      return render :retired, status: :gone if retired?(export)
      return render :expired, status: :gone unless export.status == "completed" && ExportJob.export_exists?(export.operation_id)

      send_file ExportJob.download_path(export.operation_id), type: "application/sql", disposition: "attachment", filename: download_name(export)
    end

    private

    # @return [String] "sql", or "json" (retired) for any other row: one whose details say json, or that
    #   names no format (an export made before the format choice existed was JSON)
    def export_format(export)
      export.details&.dig("format") == ExportJob::FORMAT ? ExportJob::FORMAT : RETIRED_FORMAT
    end

    def retired?(export) = export_format(export) == RETIRED_FORMAT

    # Named after its root, as graph_mem:export_sql names its default file ("synthprj.sql": one root;
    # "synthprj_plus_2.sql": three), so it reads as that project's script.
    def download_name(export)
      base = Array(export.details&.dig("root_names")).first.to_s.parameterize(separator: "_")
      return "graph_mem_export_#{export.created_at.strftime('%Y%m%d_%H%M%S')}.sql" if base.blank?

      extra = Array(export.details&.dig("entity_ids")).size - 1
      "#{base}#{"_plus_#{extra}" if extra.positive?}.sql"
    end

    def load_index
      @query = params[:q].to_s.strip.presence
      # One more than the cap, so the hint shows only when something was cut.
      roots = SqlExport::Roots.list(query: @query, limit: SqlExport::Roots::LIMIT + 1)
      @roots_capped = roots.size > SqlExport::Roots::LIMIT
      @roots = roots.first(SqlExport::Roots::LIMIT)
      @exports = OperationProgress.where(operation_type: "export").order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end
  end
end
