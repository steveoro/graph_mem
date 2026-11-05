# frozen_string_literal: true

class ProjectScanner
  # How a scan treats the Project roots its items name (1.73.1). Private methods of ProjectScanner;
  # they read its instance variables.
  #
  # - An item naming the scanned project (name or alias) is its root (ProjectScanner folds it).
  # - An item naming **another** Project root (say goggles_api's Gemfile naming goggles_db) isn't
  #   created inside the scanned project: the scanned root gets one LINK_RELATION to that root, unless
  #   the two are already related either way, and the name resolves to that root for every other
  #   item's relations. Nothing is written to the other project: not its facts, not a `part_of`.
  # - An item typed as a project with no such root becomes an ITEM_TYPE_FOR_PROJECT entity.
  # Names match ignoring case and treating "-", "_" and spaces alike (goggles-db is goggles_db).
  module ProjectLinks
    # The relation from the scanned project's root to another root one of its items names.
    LINK_RELATION = "depends_on"

    private

    # @return [Boolean] "Project" or one of its vocabulary aliases (repo, repository, codebase, …),
    #   whether or not the database's type mappings know them
    def project_type?(type)
      project = NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      type.casecmp?(project) || GraphVocabulary::ENTITY_TYPE_MAPPINGS.fetch(project).include?(type.downcase)
    end

    # @return [Boolean] the name (or one of the aliases) of the scanned project's root
    def project_root_name?(name)
      @project_entity.present? && root_keys(@project_entity).include?(project_key(name))
    end

    # @return [MemoryEntity, nil] another Project root whose name or alias matches
    def other_project_root(name)
      return nil if @project_entity.nil?

      @other_roots ||= MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil)
                                   .where.not(id: @project_entity.id).order(:id).to_a
                                   .each_with_object({}) { |root, keys| root_keys(root).each { |key| keys[key] ||= root } }
      @other_roots[project_key(name)]
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
