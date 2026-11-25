# frozen_string_literal: true

module SqlExport
  # What one graph_mem-sql export carries, as ids (SqlExport::Writer reads the rows):
  #
  # - a Project root: itself and ProjectMembership.member_ids (the part_of tree that matches
  #   project_id), plus, with `include_nested`, every Project nested in that tree with its own members;
  # - a non-Project root (a global such as "User Preferences"): itself and the global entities its
  #   part_of tree owns (the same walk), plus nested Projects the same way.
  #
  # Every observation of those entities, one per (entity, SHA2(content)): the active copy, else the
  # highest id, with the supersede/outdated links of each dropped copy pointing at the kept one. Every
  # relation with an end in the set; its other end, when outside, is a reference (#ref_ids).
  #
  #   scope = SqlExport::Scope.new([ project.id ])
  #   scope.entity_roots   # => { 12 => nil, 40 => 12, 41 => 12 } (entity id => its Project root, nil: global scope)
  #   scope.observation_ids # => [501, 502, ...] (kept copies, by entity then id)
  #   scope.link(503)      # => 502 (a dropped duplicate maps to its kept copy)
  class Scope
    BATCH = 1_000

    attr_reader :roots, :entity_roots, :observation_ids, :relation_ids, :ref_ids

    # @param root_ids [Array<Integer>] Project roots or global entities
    # @param include_nested [Boolean] also export the Projects nested in their trees
    # @raise [ArgumentError] for an unknown id, or an entity that is a member of a project
    def initialize(root_ids, include_nested: true)
      @include_nested = include_nested
      @roots = MemoryEntity.where(id: root_ids).order(:id).to_a
      missing = root_ids.map(&:to_i) - @roots.map(&:id)
      raise ArgumentError, "no entity with id #{missing.join(', ')}" if missing.any?

      member = @roots.find(&:project_id)
      raise ArgumentError, "'#{member.name}' is a member of a project: export its Project instead" if member

      @entity_roots = {}
      @roots.each { |root| add_tree(root) }
      plan_observations
      plan_relations
    end

    # @param observation_id [Integer, nil]
    # @return [Integer, nil] the kept copy the id stands for, nil when it is outside the export
    def link(observation_id)
      return nil unless observation_id

      @kept_for[observation_id]
    end

    private

    def add_tree(root)
      return if @entity_roots.key?(root.id)

      project = root.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      @entity_roots[root.id] = nil
      ids = ProjectMembership.member_ids(root.id).to_a
      ids.each { |id| @entity_roots[id] ||= project ? root.id : nil }
      return unless @include_nested

      MemoryEntity.where(id: nested_project_ids([ root.id ] + ids)).order(:id).each { |nested| add_tree(nested) }
    end

    # Projects with an owned part_of edge into the given entities (ProjectMembership.member_ids stops there).
    def nested_project_ids(ids)
      ids.each_slice(BATCH).flat_map do |slice|
        MemoryRelation.where(to_entity_id: slice, relation_type: "part_of").where(ProjectMembership::OWNED_EDGE_SQL)
                      .joins(:from_entity).where(memory_entities: { entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE })
                      .pluck(:from_entity_id)
      end
    end

    # Keeps one observation per (entity, content digest), chosen like the importer matches: active
    # first, then the highest id. The digest is MariaDB's SHA2, the one the importer compares.
    def plan_observations
      @observation_ids = []
      @kept_for = {}
      @entity_roots.keys.each_slice(BATCH) do |slice|
        rows = MemoryObservation.where(memory_entity_id: slice)
                                .pluck(:id, :memory_entity_id, Arel.sql("SHA2(content, 256)"), Arel.sql("status = 'active'"))
        rows.group_by { |_, entity_id, digest, _| [ entity_id, digest ] }.sort_by { |(entity_id, _), group| [ entity_id, group.map(&:first).min ] }
            .each do |_, group|
              kept = group.max_by { |id, _, _, active| [ active.to_i, id ] }.first
              @observation_ids << kept
              group.each { |id, *| @kept_for[id] = kept }
            end
      end
    end

    def plan_relations
      ids = @entity_roots.keys
      found = ids.each_slice(BATCH).flat_map do |slice|
        MemoryRelation.where(from_entity_id: slice).or(MemoryRelation.where(to_entity_id: slice)).pluck(:id, :from_entity_id, :to_entity_id)
      end.uniq
      @relation_ids = found.map(&:first).sort
      @ref_ids = found.flat_map { |_, from, to| [ from, to ] }.uniq.reject { |id| @entity_roots.key?(id) }.sort
    end
  end
end
