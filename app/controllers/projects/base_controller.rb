# frozen_string_literal: true

module Projects
  # Projects & Data (UI-6): projects, scans, imports, exports and the background-job controls.
  # Operator only: no subclass calls allow_guest, so a guest gets 403 from every action
  # (RoleAuthorization), and every write keeps ApplicationController's CSRF check.
  #
  # `nav_section` names the sidebar entry a page belongs to (ui/_sidebar reads it from the
  # controller class), so the detail pages under a section keep that entry current.
  class BaseController < ApplicationController
    class_attribute :nav_section, instance_writer: false, default: :projects

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    private

    def render_not_found(_error = nil)
      render "projects/not_found", status: :not_found
    end

    # @return [Boolean] whether `raw` is a UUID (operation and import-session ids are), so it can
    #   be looked up or joined into a temp-file name safely
    def uuid?(raw)
      raw.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    # @return [OperationProgress] raises RecordNotFound (404) unless `raw` is a known operation
    #   id of one of `types`
    def find_operation!(raw, types)
      raise ActiveRecord::RecordNotFound, "Operation not found" unless uuid?(raw)

      OperationProgress.find_by!(operation_id: raw.to_s, operation_type: types)
    end
  end
end
