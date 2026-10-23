# frozen_string_literal: true

class ScanProjectTool < ApplicationTool
  MODES = %w[initial rescan validate].freeze

  def self.tool_name
    "scan_project"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: false,
    open_world_hint: true
  )

  description "Enqueue an asynchronous filesystem scan that reconciles the knowledge graph with a project root; " \
    "returns a scan_id and does not wait. `project_root` is an absolute path under the operator's scan folders " \
    "(see `scan_project_status` / the Settings page); hidden folders are never scannable. " \
    "Optional: `project_name` (string), " \
    "`aliases` (comma- or pipe-separated string), `mode` (initial, rescan, or validate; default initial), " \
    "`dry_run` (bool), `file_globs` (array of strings), `scan_id` (string, resume a paused validation batch). " \
    "Do not use to poll completion; use `scan_project_status` instead. " \
    "Do not use to create a single node by hand; use `graph_write` instead. " \
    "Do not use to scope searches to a project already in the graph; use `set_context` instead."

  arguments do
    required(:project_root).filled(:string).description("Absolute path of the project folder, under the operator's scan folders.")
    optional(:project_name).maybe(:string).description("Preferred project name. Defaults to the directory name or the LLM-extracted name.")
    optional(:aliases).maybe(:string).description("Comma- or pipe-separated aliases for the project root entity.")
    optional(:mode).filled(:string).description("Scan mode: initial, rescan, or validate. Default: initial.")
    optional(:dry_run).maybe(:bool).description("When true, preview changes without writing to the graph.")
    optional(:file_globs).array(:string).description("Optional file globs to scan, relative to project_root.")
    optional(:scan_id).maybe(:string).description("Existing scan operation_id to resume a paused validation batch. If omitted, a new scan is started.")
  end

  def call(project_root:, project_name: nil, aliases: nil, mode: "initial", dry_run: false, file_globs: [], scan_id: nil)
    resolution = ScanRootPolicy.resolve(project_root)
    raise FastMcp::Tool::InvalidArgumentsError, resolution.message unless resolution.ok?

    if (bad_glob = ProjectScanFileFilter.new(resolution.path).invalid_glob(file_globs))
      raise FastMcp::Tool::InvalidArgumentsError,
            "file_globs entry #{bad_glob.inspect} must be relative to project_root, without '..'"
    end

    unless MODES.include?(mode.to_s.downcase)
      raise FastMcp::Tool::InvalidArgumentsError, "mode must be one of: #{MODES.join(', ')}"
    end

    resumed = scan_id.to_s.present?
    scan_id = scan_id.to_s.presence || SecureRandom.uuid
    expanded_root = resolution.path

    ProjectScanJob.perform_later(
      scan_id,
      expanded_root,
      project_name.to_s.presence,
      aliases.to_s.presence,
      mode.to_s.downcase,
      dry_run == true,
      file_globs
    )

    {
      scan_id: scan_id,
      status: "queued",
      resumed: resumed,
      project_root: expanded_root,
      warnings: resolution.warnings.map(&:to_s),
      mode: mode.to_s.downcase,
      dry_run: dry_run == true
    }
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "ScanProjectTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end
