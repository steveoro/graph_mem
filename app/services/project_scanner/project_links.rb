# frozen_string_literal: true

class ProjectScanner
  # How a scan treats the Project roots its items name (1.73.1). Private methods of ProjectScanner;
  # they read its instance variables.
  #
  # - An item naming the scanned project (name or alias) is its root (ProjectScanner folds it).
  # - A project-like item (typed as a project, a gem or a framework) naming **another** Project root
  #   (say goggles_api's Gemfile naming goggles_db) isn't created inside the scanned project: the
  #   scanned root gets one LINK_RELATION to that root, unless the two are already related either
  #   way. Any other item sharing a root's name stays a local entity. A relation's target resolves to
  #   the scanned project's own entities first, then to another root. Nothing is written to the other
  #   project: not its facts, not a `part_of`.
  # - A name two roots share (after normalization, or one root's alias being another's name) matches
  #   neither: no link, counted in #ambiguous_root_names.
  # - An item typed as a project with no such root becomes an ITEM_TYPE_FOR_PROJECT entity.
  # Names match ignoring case and treating "-", "_" and spaces alike (goggles-db is goggles_db).
  module ProjectLinks
    # The relation from the scanned project's root to another root one of its items names.
    LINK_RELATION = "depends_on"
    # Canonical types (besides the project types) whose items may name another project.
    LIBRARY_TYPES = %w[Gem Framework].freeze

    private

    # @return [Boolean] "Project" or one of its vocabulary aliases (repo, repository, codebase, …),
    #   whether or not the database's type mappings know them
    def project_type?(type)
      project = NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      type.casecmp?(project) || GraphVocabulary::ENTITY_TYPE_MAPPINGS.fetch(project).include?(type.downcase)
    end

    # @return [Boolean] a project type, or a library type (Gem, Framework) or one of their
    #   vocabulary aliases (gem, rubygem, library, …)
    def project_like_type?(type)
      project_type?(type) || LIBRARY_TYPES.any? do |library|
        type.casecmp?(library) || GraphVocabulary::ENTITY_TYPE_MAPPINGS.fetch(library).include?(type.downcase)
      end
    end

    # @return [Boolean] the name (or one of the aliases) of the scanned project's root
    def project_root_name?(name)
      @project_entity.present? && root_keys(@project_entity).include?(project_key(name))
    end

    # @return [MemoryEntity, nil] the one other Project root whose name or alias matches; nil when
    #   none does, or when several do (counted in #ambiguous_root_names)
    def other_project_root(name)
      return nil if @project_entity.nil?

      roots = other_roots_by_key.fetch(project_key(name), [])
      return roots.first if roots.size <= 1

      (@ambiguous_root_names ||= Set.new) << project_key(name)
      nil
    end

    # @return [Integer] the distinct names this scan couldn't link because several roots match them
    def ambiguous_root_names
      @ambiguous_root_names&.size.to_i
    end

    # One numbers-only `[scan]` line for the reconcile's counters, when any is positive (no names: logs
    # stay clean): names several roots matched, and stored entities the model typed differently.
    def report_reconcile_counts!
      counts = { ambiguous_project_roots: ambiguous_root_names, type_mismatches: @type_mismatches.to_i }
      return unless counts.values.any?(&:positive?)

      @logger.info("[scan] #{JSON.generate({ scan_id: @scan_id }.merge(counts))}")
    end

    def other_roots_by_key
      @other_roots_by_key ||= MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
                                          .where.not(id: @project_entity.id).order(:id).to_a
                                          .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |root, keys|
        root_keys(root).uniq.each { |key| keys[key] << root unless keys[key].include?(root) }
      end
    end

    # One LINK_RELATION from the scanned root to `root`, unless the two are already related.
    def link_project!(root)
      return if @dry_run || @project_entity.nil?
      return if MemoryRelation.where(from_entity_id: @project_entity.id, to_entity_id: root.id)
                              .or(MemoryRelation.where(from_entity_id: root.id, to_entity_id: @project_entity.id)).exists?

      MemoryRelation.create!(from_entity_id: @project_entity.id, to_entity_id: root.id, relation_type: LINK_RELATION,
                             properties: { source: scan_source("reconcile"), scan_id: @scan_id })
      @relations_created_count += 1
    end

    # @return [Boolean] a `part_of` into another Project root: ownership across projects, never written
    def part_of_another_root?(target, relation_type)
      relation_type == "part_of" && target.project_root? && target.id != @project_entity&.id
    end

    def root_keys(root)
      ([ root.name ] + root.aliases.to_s.split(/[,|;]/)).map { |name| project_key(name) }.reject(&:empty?)
    end

    def project_key(name)
      name.to_s.strip.downcase.gsub(/[\s_-]+/, "_")
    end
  end
end
