# frozen_string_literal: true

class ScanProjectTool < ApplicationTool
  MODES = %w[initial rescan validate].freeze

  def self.tool_name
    "scan_project"
  end

  description "Scan a project root directory and reconcile the knowledge graph with the source. " \
    "Returns a scan_id; the scan runs asynchronously via Solid Queue. " \
    "If LLM summarization is disabled or unreachable, the scan falls back to a " \
    "deterministic extraction of project metadata, manifest files, and top-level directories. " \
    "Use scan_project_status to poll for completion."

  arguments do
    required(:project_root).filled(:string).description("Absolute or relative path to the project root directory.")
    optional(:project_name).maybe(:string).description("Preferred project name. Defaults to the directory name or the LLM-extracted name.")
    optional(:aliases).maybe(:string).description("Comma- or pipe-separated aliases for the project root entity.")
    optional(:mode).filled(:string).description("Scan mode: initial, rescan, or validate. Default: initial.")
    optional(:dry_run).maybe(:bool).description("When true, preview changes without writing to the graph.")
    optional(:file_globs).array(:string).description("Optional file globs to scan, relative to project_root.")
  end

  def call(project_root:, project_name: nil, aliases: nil, mode: "initial", dry_run: false, file_globs: [])
    unless File.directory?(File.expand_path(project_root.to_s))
      raise FastMcp::Tool::InvalidArgumentsError, "Project root does not exist or is not a directory"
    end

    unless MODES.include?(mode.to_s.downcase)
      raise FastMcp::Tool::InvalidArgumentsError, "mode must be one of: #{MODES.join(', ')}"
    end

    scan_id = SecureRandom.uuid
    expanded_root = File.expand_path(project_root.to_s)

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
      project_root: expanded_root,
      mode: mode.to_s.downcase,
      dry_run: dry_run == true
    }
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "ScanProjectTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "Failed to enqueue project scan: #{e.message}"
  end
end
