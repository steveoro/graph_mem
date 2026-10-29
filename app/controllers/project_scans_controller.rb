# frozen_string_literal: true

# The Maintenance hub's scan form endpoint, kept until §6.D-6: it starts the scan through
# ProjectScanLauncher (like Projects::ScansController#create) and redirects to the new pages.
class ProjectScansController < ApplicationController
  def create
    result = ProjectScanLauncher.call(params.permit(:project_root, :project_name, :aliases, :mode, :file_globs, :dry_run))
    return redirect_to new_projects_scan_path, alert: result.error unless result.ok?

    redirect_to projects_scan_path(result.operation_id),
                notice: "Project scan queued for #{result.path}. Scan ID: #{result.operation_id}.#{result.warnings}"
  rescue StandardError => e
    Rails.logger.error "Project scan trigger failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to new_projects_scan_path, alert: "Failed to queue project scan: #{e.message}"
  end
end
