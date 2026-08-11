# frozen_string_literal: true

require "pathname"

class ProjectScansController < ApplicationController
  def create
    project_root = params[:project_root].to_s.strip
    return redirect_to root_path, alert: "Project root is required." if project_root.blank?

    expanded_root = File.expand_path(project_root)
    unless File.directory?(expanded_root)
      return redirect_to root_path, alert: "Project root is not a directory: #{project_root}"
    end

    real_root = Pathname.new(expanded_root).realpath.to_s
    unless allowed_root?(real_root)
      return redirect_to root_path, alert: "Project root is outside the allowed scan directories."
    end

    mode = params[:mode].to_s.downcase.presence || "initial"
    unless ScanProjectTool::MODES.include?(mode)
      return redirect_to root_path, alert: "Mode must be one of: #{ScanProjectTool::MODES.join(', ')}"
    end

    scan_id = SecureRandom.uuid
    ProjectScanJob.perform_later(
      scan_id,
      expanded_root,
      params[:project_name].to_s.presence,
      params[:aliases].to_s.presence,
      mode,
      params[:dry_run] == "1",
      file_globs_param
    )

    redirect_to root_path, notice: "Project scan queued for #{expanded_root}. Scan ID: #{scan_id}"
  rescue StandardError => e
    Rails.logger.error "Project scan trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to root_path, alert: "Failed to queue project scan: #{e.message}"
  end

  private

  def allowed_scan_roots
    AppSettings.project_scan_root_paths
  end

  def allowed_root?(real_path)
    allowed_scan_roots.any? do |root|
      allowed_real = Pathname.new(root).realpath.to_s
      real_path == allowed_real || real_path.start_with?("#{allowed_real}/")
    rescue SystemCallError, ArgumentError
      real_path == root || real_path.start_with?("#{root}/")
    end
  end

  def file_globs_param
    globs = params[:file_globs].to_s.split(/[\r\n,]+/).map(&:strip).reject(&:blank?)
    globs.presence
  end
end
