# frozen_string_literal: true

module Projects
  # Async exports (UI-6 P5): pick roots and a format (a graph_mem-sql script, preselected, or the GraphMem
  # JSON tree), ExportJob writes the file in the background while the progress page follows it over
  # OperationProgressChannel, then download it. The format is kept in the operation's details; a row
  # without one is a JSON export. Files are removed hourly (ExportJob.cleanup_old_exports in
  # config/recurring.yml); an expired one answers 410. The download path comes only from
  # ExportJob.download_path(<a known export's UUID>, format:).
  #
  # The script is sent as application/sql (RFC 6922, the registered type), always as an attachment, so
  # a browser saves it instead of rendering it; plain text would be shown inline by some.
  class ExportsController < BaseController
    self.nav_section = :exports
    PER_PAGE = 25
    MAX_ROOTS = ExportStrategy::ROOT_NODES_LIMIT
    helper_method :export_format
    ROOT_NAMES_KEPT = 20
    DEFAULT_FORMAT = "sql"
    CONTENT_TYPES = { "sql" => "application/sql", "json" => "application/json" }.freeze

    # GET /projects/exports(?q=): the root picker (Projects first, capped) and past exports
    def index
      load_index
    end

    # POST /projects/exports (ids[], export_format = sql | json, sql when absent)
    def create
      format = params[:export_format].presence || DEFAULT_FORMAT
      unless ExportJob::FORMATS.include?(format)
        @error = t("projects.exports.unknown_format")
        load_index
        return render :index, status: :unprocessable_content
      end

      roots = MemoryEntity.where(id: Array(params[:ids]).filter_map { |raw| EntityIdList.id(raw.to_s) }.first(MAX_ROOTS))
                          .order(:name).pluck(:id, :name)
      if roots.empty?
        @error = t("projects.exports.pick_one")
        load_index
        return render :index, status: :unprocessable_content
      end

      export_id = SecureRandom.uuid
      OperationProgress.create!(operation_type: "export", operation_id: export_id, status: "pending", message: "Export queued",
                                details: { "entity_ids" => roots.map(&:first), "root_names" => roots.map(&:last).first(ROOT_NAMES_KEPT), "format" => format })
      ExportJob.perform_later(export_id, roots.map(&:first))
      redirect_to projects_export_path(export_id)
    end

    # GET /projects/exports/:operation_id: progress, then the download link
    def show
      @export = find_operation!(params[:operation_id], "export")
      @file_available = ExportJob.export_exists?(@export.operation_id, format: export_format(@export))
    end

    # GET /projects/exports/:operation_id/download (410 once the file has been cleaned up)
    def download
      export = find_operation!(params[:operation_id], "export")
      format = export_format(export)
      return render :expired, status: :gone unless export.status == "completed" && ExportJob.export_exists?(export.operation_id, format: format)

      send_file ExportJob.download_path(export.operation_id, format: format), type: CONTENT_TYPES.fetch(format), disposition: "attachment",
                                                                              filename: download_name(export, format)
    end

    private

    # An export row without a format (made before the choice existed) is JSON.
    def export_format(export)
      format = export.details&.dig("format")
      ExportJob::FORMATS.include?(format) ? format : ExportJob::DEFAULT_FORMAT
    end

    # JSON: graph_mem_export_<time>.json. A script is named after its root, as graph_mem:export_sql names its
    # default file ("synthprj.sql": one root; "synthprj_plus_2.sql": three), so it reads as that project's script.
    def download_name(export, format)
      stamp = export.created_at.strftime("%Y%m%d_%H%M%S")
      return "graph_mem_export_#{stamp}.json" if format == "json"

      base = Array(export.details&.dig("root_names")).first.to_s.parameterize(separator: "_")
      return "graph_mem_export_#{stamp}.sql" if base.blank?

      extra = Array(export.details&.dig("entity_ids")).size - 1
      "#{base}#{"_plus_#{extra}" if extra.positive?}.sql"
    end

    def load_index
      @export_format = ExportJob::FORMATS.include?(params[:export_format]) ? params[:export_format] : DEFAULT_FORMAT
      @query = params[:q].to_s.strip.presence
      # One more than the cap, so the hint shows only when something was cut.
      roots = ExportStrategy.new.root_nodes(query: @query, limit: ExportStrategy::ROOT_NODES_LIMIT + 1)
      @roots_capped = roots.size > ExportStrategy::ROOT_NODES_LIMIT
      @roots = roots.first(ExportStrategy::ROOT_NODES_LIMIT)
      @exports = OperationProgress.where(operation_type: "export").order(created_at: :desc, id: :desc).page(params[:page]).per(PER_PAGE)
    end
  end
end
