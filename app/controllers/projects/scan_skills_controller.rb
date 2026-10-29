# frozen_string_literal: true

module Projects
  # Continue or stop a guided scan from its detail page (UI-6 P3).
  class ScanSkillsController < BaseController
    self.nav_section = :scans

    # PATCH /projects/scan_skills/:operation_id?skill_action=continue|stop
    def update
      operation = find_operation!(params[:operation_id], "project_scan_skill")
      ok, message = ProjectScanLauncher.steer(operation, params[:skill_action])
      redirect_to projects_scan_path(operation.operation_id), (ok ? :notice : :alert) => message
    end
  end
end
