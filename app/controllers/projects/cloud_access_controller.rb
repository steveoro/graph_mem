# frozen_string_literal: true

module Projects
  # Turns cloud access on or off for one project (agent-CLI PR2): whether its data, anonymized,
  # may go to a cloud model once one is configured (none is until PR4). The only place
  # `cloud_allowed` can be set: operator only (BaseController), in a change set of kind
  # `project.cloud_access`, audited by Auditable and undoable like any audited change.
  class CloudAccessController < BaseController
    # PATCH /projects/cloud_access/:id with allowed=true|false
    # @return [void] redirects to the Projects page; 404 for anything but a Project root, 422 for
    #   another `allowed` value
    def update
      project = MemoryEntity.find_by!(id: params[:id], entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
      allowed = { "true" => true, "false" => false }[params[:allowed].to_s]
      return head :unprocessable_content if allowed.nil?

      state = allowed ? "on" : "off"
      ChangeSet.record(kind: "project.cloud_access", subject: project, summary: t("projects.cloud_access.summary_#{state}", project: project.name)) do
        project.update!(cloud_allowed: allowed)
      end
      redirect_to projects_path, notice: t("projects.cloud_access.#{state}", project: project.name)
    end
  end
end
