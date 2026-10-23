# frozen_string_literal: true

class ProjectScansController < ApplicationController
  include ScanRootResolution

  def create
    resolution = resolve_scan_root(params[:project_root])
    return redirect_to root_path, alert: resolution.message unless resolution.ok?

    real_root = resolution.path

    mode = params[:mode].to_s.downcase.presence || "initial"
    unless ScanProjectTool::MODES.include?(mode)
      return redirect_to root_path, alert: "Mode must be one of: #{ScanProjectTool::MODES.join(', ')}"
    end

    scan_id = SecureRandom.uuid
    OperationProgress.create!(
      operation_type: "project_scan",
      operation_id: scan_id,
      status: "pending",
      total_count: 6,
      current_count: 0,
      percentage: 0,
      phase: "queued",
      message: "Queued project scan",
      details: {
        project_root: real_root,
        project_name: params[:project_name].to_s.presence,
        mode: mode,
        dry_run: params[:dry_run] == "1"
      }
    )

    ProjectScanJob.perform_later(
      scan_id,
      real_root,
      params[:project_name].to_s.presence,
      params[:aliases].to_s.presence,
      mode,
      params[:dry_run] == "1",
      file_globs_param
    )

    redirect_to root_path, notice: "Project scan queued for #{real_root}. Scan ID: #{scan_id}." \
                                   "#{scan_root_warning_suffix(resolution)}"
  rescue StandardError => e
    Rails.logger.error "Project scan trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to root_path, alert: "Failed to queue project scan: #{e.message}"
  end

  private

  def file_globs_param
    globs = params[:file_globs].to_s.split(/[\r\n,]+/).map(&:strip).reject(&:blank?)
    globs.presence
  end
end
