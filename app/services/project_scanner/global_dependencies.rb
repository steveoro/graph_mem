# frozen_string_literal: true

class ProjectScanner
  # Dream State R1b: how a scan treats a library the graph already holds as one global node. After
  # a `relation_retype` swap a library (an entity of a dependency-like type, DependencyLikeTypes)
  # is global, with a `depends_on` from each project that uses it, and a scan looks names up in the
  # scanned project only, so it would make a second, project-scoped copy under `part_of` on every
  # scan. Instead:
  #
  # - an item of a dependency-like type whose name (as the scan matches names: stripped, the
  #   column's collation) is held by a **global** entity of a dependency-like type is that entity,
  #   when the scanned project has no entity of that name itself: no project copy, no `part_of`
  #   (neither Containment's nor a model-emitted one), and its project_id is never touched;
  # - a model-emitted `part_of` from one of the project's own items to such a global node isn't
  #   written either (it would move the item out of the project): Containment parents it on the root;
  # - the scan adds `Project depends_on` it when the edge is missing;
  # - its facts go onto it as scan-sourced facts whose source names the project
  #   (`project_scan:<scan id>:dependency:<project id>`), so the project's scan validation covers
  #   them (ProjectScanValidator::Scope) and a later scan that no longer names the entity
  #   obsoletes them (#mark_missing_dependencies), as it does for the project's own entities. The
  #   other projects' facts on the node are never touched.
  #
  # Without a global namesake the scan behaves as before. Private methods of ProjectScanner; they
  # read and set its instance variables.
  module GlobalDependencies
    DEPENDENCY_PHASE = "dependency"
    DEPENDENCY_RELATION = "depends_on"

    # @param source [String, nil] an observation's source
    # @param project_id [Integer]
    # @return [Boolean] a fact a scan of that project wrote onto a global dependency
    def self.fact_source?(source, project_id)
      source.to_s.start_with?("project_scan:") && source.to_s.end_with?(":#{DEPENDENCY_PHASE}:#{project_id}")
    end

    # The global entities of a dependency-like type the project depends_on.
    # @param project [MemoryEntity] a Project root
    # @return [Array<Integer>]
    def self.entity_ids(project)
      types = DependencyLikeTypes.current
      return [] if project.nil? || types.empty? || types.stored_types.empty?

      MemoryEntity.where(project_id: nil, entity_type: types.stored_types)
                  .where(id: MemoryRelation.where(from_entity_id: project.id, relation_type: DEPENDENCY_RELATION).select(:to_entity_id))
                  .order(:id).pluck(:id)
    end

    private

    # @return [MemoryEntity, nil] the global entity an item of a dependency-like type resolves to
    def global_dependency(name, type)
      return nil if @project_entity.nil? || !scan_dependency_types.match?(type)

      entity = MemoryEntity.find_by(name: name, project_id: nil)
      return nil unless scan_dependency_types.entity?(entity)

      (@global_dependency_ids ||= Set.new) << entity.id
      entity
    end

    # @return [Boolean] the entity is a global dependency this scan resolved an item to
    def global_dependency?(entity)
      @global_dependency_ids.present? && @global_dependency_ids.include?(entity&.id)
    end

    # The scanned project's depends_on the global dependency, unless it exists.
    def link_dependency!(entity)
      return if @dry_run || @project_entity.nil?
      return if MemoryRelation.exists?(from_entity_id: @project_entity.id, to_entity_id: entity.id, relation_type: DEPENDENCY_RELATION)

      MemoryRelation.create!(from_entity_id: @project_entity.id, to_entity_id: entity.id, relation_type: DEPENDENCY_RELATION,
                             properties: { source: scan_source("reconcile"), scan_id: @scan_id })
      @relations_created_count += 1
    end

    # A part_of the scan never writes:
    # - from a global dependency: it would stamp the shared node into a scope;
    # - to one (this scan's, or a global entity of a dependency-like type the target lookup found):
    #   MembershipSync would move the project's own item out to the global scope. Containment
    #   parents such an item on the root instead.
    # @param from_entity [MemoryEntity]
    # @param target [MemoryEntity]
    # @param relation_type [String] canonical
    # @return [Boolean]
    def dependency_part_of?(from_entity, target, relation_type)
      relation_type == "part_of" && (global_dependency?(from_entity) || global_dependency_target?(target))
    end

    # @return [Boolean] a global entity of a dependency-like type
    def global_dependency_target?(target)
      global_dependency?(target) || (target.project_id.nil? && scan_dependency_types.entity?(target))
    end

    # @return [String] the source of a fact the scan writes onto `entity`
    def fact_source_for(entity)
      global_dependency?(entity) ? scan_source("#{DEPENDENCY_PHASE}:#{@project_entity.id}") : scan_source("reconcile")
    end

    # A complete scan that no longer names a global dependency of the project obsoletes the facts
    # the project's earlier scans wrote onto it (never another project's, never a manual one). The
    # node and its depends_on stay.
    # @param scanned_ids [Array<Integer>] the entities this scan reconciled
    def mark_missing_dependencies(scanned_ids)
      ids = GlobalDependencies.entity_ids(@project_entity) - scanned_ids
      return if ids.empty?

      MemoryObservation.active.where(memory_entity_id: ids).find_each do |observation|
        next unless GlobalDependencies.fact_source?(observation.source, @project_entity.id) && from_prior_scan?(observation.source)

        observation.mark_obsolete!(reason: "not found in project scan")
        @observations_obsoleted_count += 1
      end
    end

    def scan_dependency_types
      @scan_dependency_types ||= DependencyLikeTypes.current
    end
  end
end
