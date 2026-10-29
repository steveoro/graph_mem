# frozen_string_literal: true

# Starts and steers project scans for the web forms (UI-6 P3), exactly as the Maintenance hub's
# two controllers did: the typed path goes through ScanRootPolicy first, so a refused path never
# enqueues anything; a normal scan goes through ProjectScanJob.enqueue, a guided one writes its
# pending OperationProgress and queues ProjectScanSkillJob.
#
#   result = ProjectScanLauncher.call(project_root: "/scan/alpha", mode: "initial", dry_run: "1")
#   result.ok?          # => true
#   result.operation_id # => "9b2c…" (the scan detail page's id)
#   result.warnings     # => " Warning: the scan folder is mounted read-write; …" or ""
#   ProjectScanLauncher.call(project_root: "/scan/alpha", guided: "1", depths: %w[birds_eye])
class ProjectScanLauncher
  DEPTH_OPTIONS = %w[birds_eye architecture usage ui tests_and_docs].freeze

  Result = Data.define(:ok, :operation_id, :path, :warnings, :error) do
    def ok? = ok
  end

  # @param params [Hash, ActionController::Parameters] project_root, project_name, aliases, dry_run
  #   ("1"), guided ("1"), and mode + file_globs (newline/comma separated) for a normal scan or
  #   depths (Array) for a guided one
  # @return [Result]
  def self.call(params)
    new(params).call
  end

  # Continue a paused (or still pending) guided scan, or stop one.
  #
  # @param operation [OperationProgress] a project_scan_skill operation
  # @param action [String] "continue" or "stop"
  # @return [Array(Boolean, String)] whether it worked, and the message to show
  def self.steer(operation, action)
    case action.to_s
    when "continue"
      return [ false, "Guided scan cannot be continued from #{operation.status} state." ] unless operation.status.in?(%w[pending paused])

      operation.resume!(message: "Resuming guided scan")
      OperationProgressBroadcaster.call(operation)
      ProjectScanSkillJob.perform_later(operation.operation_id)
      [ true, "Guided project scan resumed. Scan ID: #{operation.operation_id}" ]
    when "stop"
      ProjectScanSkill.new(operation).stop!
      [ true, "Guided project scan stopped. Scan ID: #{operation.operation_id}" ]
    else
      [ false, "Unknown skill action." ]
    end
  end

  def initialize(params)
    @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h.with_indifferent_access : params.to_h.with_indifferent_access
  end

  # @return [Result]
  def call
    resolution = ScanRootPolicy.resolve(@params[:project_root])
    return failure(resolution.message) unless resolution.ok?

    guided? ? launch_guided(resolution) : launch_normal(resolution)
  end

  # @return [Boolean]
  def guided?
    @params[:guided].to_s == "1"
  end

  private

  def launch_normal(resolution)
    mode = @params[:mode].to_s.downcase.presence || "initial"
    return failure("Mode must be one of: #{ScanProjectTool::MODES.join(', ')}") unless ScanProjectTool::MODES.include?(mode)

    scan_id = SecureRandom.uuid
    ProjectScanJob.enqueue(scan_id: scan_id, project_root: resolution.path, project_name: name, aliases: aliases, mode: mode,
                           dry_run: dry_run?, file_globs: file_globs)
    success(scan_id, resolution)
  end

  def launch_guided(resolution)
    depths = Array(@params[:depths]).compact_blank.presence || ProjectScanSkill::DEPTH_ORDER
    invalid = depths - DEPTH_OPTIONS
    return failure("Invalid depths: #{invalid.join(', ')}") if invalid.any?

    scan_id = SecureRandom.uuid
    OperationProgress.create!(
      operation_type: "project_scan_skill", operation_id: scan_id, status: "pending", total_count: depths.size,
      current_count: 0, percentage: 0, phase: depths.first, message: "Guided scan queued",
      details: { project_root: resolution.path, project_name: name, aliases: aliases, depths: depths,
                 current_depth_index: 0, dry_run: dry_run? }
    )
    ProjectScanSkillJob.perform_later(scan_id)
    success(scan_id, resolution)
  end

  def name = @params[:project_name].to_s.presence
  def aliases = @params[:aliases].to_s.presence
  def dry_run? = @params[:dry_run].to_s == "1"

  def file_globs
    @params[:file_globs].to_s.split(/[\r\n,]+/).map(&:strip).reject(&:blank?).presence
  end

  def success(scan_id, resolution)
    Result.new(ok: true, operation_id: scan_id, path: resolution.path, warnings: ScanRootResolution.warning_suffix(resolution), error: nil)
  end

  def failure(message)
    Result.new(ok: false, operation_id: nil, path: nil, warnings: "", error: message)
  end
end
