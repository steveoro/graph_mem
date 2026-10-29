# frozen_string_literal: true

# View helpers for Projects & Data (UI-6).
module ProjectsHelper
  # @param operation [OperationProgress] a scan or import
  # @return [String] the project it is about: the name given, the entity it created, or the folder
  def projects_operation_title(operation)
    details = operation.details || {}
    details["project_name"].presence || details["project_entity_name"].presence ||
      File.basename(details["project_root"].to_s).presence || "—"
  end

  # @param operation [OperationProgress]
  # @return [String] "normal (initial)" / "guided" for a scan
  def projects_scan_kind(operation)
    return t("projects.scans.guided") if operation.operation_type == "project_scan_skill"

    t("projects.scans.normal", mode: operation.details&.dig("mode").presence || "initial")
  end
end
