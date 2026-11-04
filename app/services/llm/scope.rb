# frozen_string_literal: true

module Llm
  # The projects a prompt's data comes from (agent-CLI PR2), resolved lazily: the Ollama path never
  # asks, so it runs no query. Llm::CloudGate checks it before any cloud call, and it holds the
  # call's (or the scan's) anonymizer session, so every part of one scan shares one mapping.
  #
  #   scope = Llm::Scope.for_entities([widget, project])  # summary evidence, a judge batch
  #   scope = Llm::Scope.for_scan(project_root: "/path/to/gadget", project_name: "Gadget Project") # one scan, all its parts
  #   scope.project_ids # => [7], or nil when some data has no project (unscoped)
  class Scope
    NO_NAME = Object.new.freeze
    private_constant :NO_NAME

    # @param entities [Array<MemoryEntity>] the entities whose text is in the prompt
    # @return [Scope] each entity's project (itself for a Project root, else its project_id);
    #   unscoped if any entity has neither
    def self.for_entities(entities)
      list = Array(entities)
      new(lambda do
        ids = list.map { |entity| entity.project_root? ? entity.id : entity.project_id }
        ids.include?(nil) ? nil : ids.uniq
      end)
    end

    # A scan's scope (agent-CLI PR4): the project comes from the folder, never from a name. The
    # folder is resolved with File.realpath; the project is the one Project root that allows cloud
    # access and whose recorded folder (Llm::CloudGate.scan_project) is that realpath, byte for byte.
    # `project_name` is only checked: it must equal that record's name exactly, else the scope is
    # unscoped (refused). A missing folder, none, no match or two matches: unscoped.
    #
    # The PR2 form, `for_scan(project_name, project_root: nil)` (a positional name), is kept for its
    # specs only: it resolves the project by name, case-insensitively. App code never calls it
    # (spec/services/llm/scope_for_scan_spec.rb checks).
    #
    # @param legacy_name [String] the PR2 form's project name (specs only)
    # @param project_root [String, nil] the folder being scanned
    # @param project_name [String, nil] the name the scan's prompts carry
    # @return [Scope]
    def self.for_scan(legacy_name = NO_NAME, project_root: nil, project_name: nil)
      return legacy_scan(legacy_name, project_root) unless legacy_name.equal?(NO_NAME)

      folder = real_folder(project_root)
      resolver = lambda do
        id, name = folder && CloudGate.scan_project(folder)
        id && name == project_name.to_s ? [ id ] : nil
      end
      new(resolver, scan_root: folder || "")
    end

    # @param path [String, nil]
    # @return [String, nil] the folder's realpath; nil when it is blank, missing or unreadable
    def self.real_folder(path)
      return nil if path.blank?

      real = File.realpath(path.to_s)
      File.directory?(real) ? real : nil
    rescue SystemCallError
      nil
    end

    # How a scan folder is shown in the Cloud confirm and recorded when Cloud is turned on: its
    # realpath, or the path as given when the folder no longer exists (a scan can't read from it,
    # and .for_scan refuses a missing folder).
    #
    # @param path [String, nil] a completed scan's project_root
    # @return [String, nil]
    def self.recorded_folder(path)
      path && (real_folder(path) || path)
    end

    def self.legacy_scan(project_name, project_root)
      resolver = lambda do
        id = MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil, name: project_name.to_s).pick(:id)
        id && [ id ]
      end
      new(resolver, scan_root: project_root ? File.expand_path(project_root.to_s) : "")
    end
    private_class_method :legacy_scan

    # @return [String, nil] a scan's folder ("" when unknown); nil for a summary or judge scope
    attr_reader :scan_root

    # @param resolver [#call] returns the project ids, or nil for unscoped data
    # @param scan_root [String, nil] see #scan_root
    def initialize(resolver, scan_root: nil)
      @resolver = resolver
      @scan_root = scan_root
      @resolved = false
    end

    # @return [Array<Integer>, nil] the projects, resolved on first use; nil when unscoped
    def project_ids
      unless @resolved
        @project_ids = @resolver.call
        @resolved = true
      end
      @project_ids
    end

    # @return [Boolean] some of the data has no project
    def unscoped?
      project_ids.nil?
    end

    # @return [Llm::Anonymizer::Session] this scope's session, built on first cloud use and kept
    #   for the scope's life (one per summary or judge call, one per scan)
    def session
      @session ||= Anonymizer::Session.new(self)
    end

    # @return [String] never the ids or names (scopes must not leak into logs or errors)
    def inspect
      "#<#{self.class.name}>"
    end
  end
end
