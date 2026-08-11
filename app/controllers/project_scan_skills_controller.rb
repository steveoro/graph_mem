# frozen_string_literal: true

require "pathname"

class ProjectScanSkillsController < ApplicationController
  DEPTH_OPTIONS = %w[birds_eye architecture usage ui tests_and_docs].freeze

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

    scan_id = SecureRandom.uuid
    depths = Array(params[:depths]).presence || ProjectScanSkill::DEPTH_ORDER
    invalid = depths - DEPTH_OPTIONS
    return redirect_to root_path, alert: "Invalid depths: #{invalid.join(', ')}" if invalid.any?

    OperationProgress.create!(
      operation_type: "project_scan_skill",
      operation_id: scan_id,
      status: "pending",
      total_count: depths.size,
      current_count: 0,
      percentage: 0,
      phase: depths.first,
      message: "Guided scan queued",
      details: {
        project_root: real_root,
        project_name: params[:project_name].to_s.presence,
        aliases: params[:aliases].to_s.presence,
        depths: depths,
        current_depth_index: 0,
        dry_run: params[:dry_run] == "1"
      }
    )

    ProjectScanSkillJob.perform_later(scan_id)

    redirect_to root_path, notice: "Guided project scan queued for #{expanded_root}. Scan ID: #{scan_id}"
  rescue StandardError => e
    Rails.logger.error "Project scan skill trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to root_path, alert: "Failed to queue guided project scan: #{e.message}"
  end

  def update
    operation = OperationProgress.find_by(operation_id: params[:id])
    return redirect_to root_path, alert: "Guided scan not found." unless operation

    case params[:skill_action]
    when "continue"
      unless operation.status.in?(%w[pending paused])
        return redirect_to root_path, alert: "Guided scan cannot be continued from #{operation.status} state."
      end

      operation.resume!(message: "Resuming guided scan")
      OperationProgressBroadcaster.call(operation)
      ProjectScanSkillJob.perform_later(operation.operation_id)
      redirect_to root_path, notice: "Guided project scan resumed. Scan ID: #{operation.operation_id}"
    when "stop"
      ProjectScanSkill.new(operation).stop!
      redirect_to root_path, notice: "Guided project scan stopped. Scan ID: #{operation.operation_id}"
    else
      redirect_to root_path, alert: "Unknown skill action."
    end
  rescue StandardError => e
    Rails.logger.error "Project scan skill update failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to root_path, alert: "Failed to update guided project scan: #{e.message}"
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
end
