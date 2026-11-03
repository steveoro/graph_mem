# frozen_string_literal: true

module Llm
  # Whether a prompt may go to a cloud provider (agent-CLI PR2): only when every project its data
  # comes from is a Project root whose operator turned cloud_allowed on (Projects page), and, for
  # a scan, only when the folder scanned is the project's cloud_root. One count
  # query per call, never cached, so turning the flag off takes effect on the next call (mid-scan
  # included). No timestamp is read.
  #
  #   Llm::CloudGate.allowed?(Llm::Scope.for_scan("Gadget Project")) # => false until allowed
  module CloudGate
    module_function

    # @param scope [Llm::Scope, nil]
    # @return [Boolean] false for no scope, unscoped data, no project, or any project not allowed
    def allowed?(scope)
      return false unless scope.is_a?(Scope)

      ids = scope.project_ids
      return false if ids.blank?

      allowed = MemoryEntity.where(id: ids, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil, cloud_allowed: true)
      unless scope.scan_root.nil?
        # A scan goes out only from the folder recorded when Cloud was turned on.
        return false if scope.scan_root.empty?

        allowed = allowed.where(cloud_root: scope.scan_root)
      end
      allowed.count == ids.uniq.size
    end
  end
end
