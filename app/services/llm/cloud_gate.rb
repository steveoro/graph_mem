# frozen_string_literal: true

module Llm
  # Whether a prompt may go to a cloud provider (agent-CLI PR2): only when every project its data
  # comes from is a Project root whose operator turned cloud_allowed on (Projects page), and, for
  # a scan, only when the folder scanned is the project's cloud_root. One query
  # per call, never cached, so turning the flag off takes effect on the next call (mid-scan
  # included). No timestamp is read.
  #
  # PR4: a scan's project comes from its folder (Llm::Scope.for_scan, through .scan_project), and a
  # cloud_root with a symlink anywhere on its path is refused, so re-pointing a link at or above
  # the recorded folder can't send another tree. Turning Cloud off and on records the new realpath.
  #
  #   Llm::CloudGate.allowed?(Llm::Scope.for_scan(project_root: "/path/to/gadget", project_name: "Gadget Project"))
  #   # => false until allowed
  module CloudGate
    module_function

    # @param scope [Llm::Scope, nil]
    # @return [Boolean] false for no scope, unscoped data, no project, or any project not allowed
    def allowed?(scope)
      return false unless scope.is_a?(Scope)

      ids = scope.project_ids
      return false if ids.blank?

      roots = MemoryEntity.where(id: ids, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil, cloud_allowed: true).pluck(:cloud_root)
      # A scan goes out only from the folder recorded when Cloud was turned on, compared byte for byte
      # in Ruby (the column's collation ignores case and accents; paths don't).
      return false unless scope.scan_root.nil? || (scope.scan_root.present? && roots.all?(scope.scan_root) && roots.all? { |root| real_path?(root) })

      roots.size == ids.uniq.size
    end

    # The project a scan of `folder` belongs to: the one Project root that allows cloud access and
    # whose cloud_root is `folder`, byte for byte (the SQL match is only a prefilter: its collation
    # ignores case and accents).
    #
    # @param folder [String] a realpath (Llm::Scope.real_folder)
    # @return [Array(Integer, String), nil] `[id, name]`; nil for no match or more than one
    def scan_project(folder)
      rows = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil, cloud_allowed: true, cloud_root: folder)
                         .pluck(:id, :name, :cloud_root).select { |_id, _name, root| root == folder }
      rows.size == 1 ? rows.first.first(2) : nil
    end

    # @param root [String, nil] a recorded cloud_root
    # @return [Boolean] an absolute, normalized path with no symlink on it (a missing tail is fine:
    #   nothing there can be re-pointed, and a scan can't read from it)
    def real_path?(root)
      return false unless root.is_a?(String) && root.start_with?("/") && File.expand_path(root) == root

      prefix = +""
      root.split("/").reject(&:empty?).each do |part|
        prefix << "/" << part
        begin
          return false if File.lstat(prefix).symlink?
        rescue Errno::ENOENT
          return true
        end
      end
      true
    rescue SystemCallError
      false
    end
  end
end
