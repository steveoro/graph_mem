# frozen_string_literal: true

module Projects
  # Turns cloud access on or off for one project (agent-CLI PR2): whether its data, anonymized,
  # may go to a cloud model once one is configured (none is until PR4). The only place
  # `cloud_allowed` (and its `cloud_root`, the folder cloud scans must come from) can be set:
  # operator only (BaseController), in a change set of kind
  # `project.cloud_access`, audited by Auditable and undoable like any audited change.
  class CloudAccessController < BaseController
    # PATCH /projects/cloud_access/:id with allowed=true|false; turning it on also sends root, the
    # folder the confirm showed ("" for none)
    # @return [void] redirects to the Projects page (with an alert, and no change, when a scan
    #   finished since the confirm changed the folder); 404 for anything but a Project root, 422
    #   for another `allowed` value
    def update
      project = MemoryEntity.find_by!(id: params[:id], entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
      allowed = { "true" => true, "false" => false }[params[:allowed].to_s]
      return head :unprocessable_content if allowed.nil?

      # Cloud scans must come from the folder of the project's last completed scan (nil: none yet),
      # recorded as its realpath (PR4): Llm::CloudGate refuses a recorded folder with a symlink on it.
      root = allowed ? Llm::Scope.recorded_folder(project.last_scan_root) : nil
      # The folder must be the one the confirm showed: a scan finished since then needs a fresh look.
      return redirect_to(projects_path, alert: t("projects.cloud_access.root_changed", project: project.name)) if allowed && params[:root].to_s != root.to_s

      state = allowed ? "on" : "off"
      ChangeSet.record(kind: "project.cloud_access", subject: project, summary: t("projects.cloud_access.summary_#{state}", project: project.name)) do
        project.update!(cloud_allowed: allowed, cloud_root: root)
      end
      notice = t("projects.cloud_access.#{state}", project: project.name)
      notice += " #{root ? t('projects.cloud_access.root', root: root) : t('projects.cloud_access.no_root')}" if allowed
      redirect_to projects_path, notice: notice
    end
  end
end
