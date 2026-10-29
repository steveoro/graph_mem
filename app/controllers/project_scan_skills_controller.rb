# frozen_string_literal: true

# The Maintenance hub's guided-scan endpoints, kept until §6.D-6: create and continue/stop go
# through ProjectScanLauncher (like the Projects::Scans pages) and redirect to the new pages.
class ProjectScanSkillsController < ApplicationController
  def create
    result = ProjectScanLauncher.call(params.permit(:project_root, :project_name, :aliases, :dry_run, depths: []).merge(guided: "1"))
    return redirect_to new_projects_scan_path, alert: result.error unless result.ok?

    redirect_to projects_scan_path(result.operation_id),
                notice: "Guided project scan queued for #{result.path}. Scan ID: #{result.operation_id}.#{result.warnings}"
  rescue StandardError => e
    Rails.logger.error "Project scan skill trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to new_projects_scan_path, alert: "Failed to queue guided project scan: #{e.message}"
  end

  def update
    operation = OperationProgress.find_by(operation_id: params[:id].to_s, operation_type: "project_scan_skill")
    return redirect_to projects_scans_path, alert: "Guided scan not found." unless operation

    ok, message = ProjectScanLauncher.steer(operation, params[:skill_action])
    redirect_to projects_scan_path(operation.operation_id), (ok ? :notice : :alert) => message
  rescue StandardError => e
    Rails.logger.error "Project scan skill update failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to projects_scans_path, alert: "Failed to update guided project scan: #{e.message}"
  end
end
