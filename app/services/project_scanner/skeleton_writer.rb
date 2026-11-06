# frozen_string_literal: true

class ProjectScanner
  # Writes a Rails code map (RailsCodeMap, 1.75.0) into a scanned project as its skeleton, inside the
  # scan's reconcile transaction. Not through ImportExecutionStrategy: that takes its own lock and
  # transaction and dedupes by embedding; the map's names are already exact. Every fact and
  # relation it writes carries RailsCodeMap::SOURCE, which it alone diffs:
  #
  # - **Entities**: an entry's entity is the project's entity of that name (any case), or a new one
  #   with the entry's type and aliases (the description stays blank for the model). A stored Class
  #   or Module takes the entry's role type ("specific beats generic"); any other stored type is
  #   kept. Aliases are unioned.
  # - **Containment**: `part_of` the root, unless the entity already has a parent.
  # - **Facts**: each entry's facts are created (confidence 1.0, perspective "world") unless the
  #   same text is already active; a "Defined at" whose line moved in the same file supersedes the
  #   old one; an own fact the entry no longer has is obsoleted.
  # - **Relations**: the map's edges are created when missing; an own relation the map no longer has
  #   becomes a `delete_relation` review item.
  # - **Gone entries**: own facts of project entities the map no longer holds are obsoleted (the
  #   scan's missing-entity pass then queues the entity for review).
  #
  # Nothing is retired (no obsolete fact or review item for a gone entry or relation) when the map
  # is incomplete, when any entry failed in this run (its live facts would look gone), or for an
  # entity whose file the extractor couldn't read. An entry that fails is rolled back to its
  # savepoint, with its counts, and reported; the others still land.
  #
  #   writer = ProjectScanner::SkeletonWriter.new(map: map, root: project, scan_id: id).call
  #   writer.entities["GogglesDb::Badge"] # => #<MemoryEntity …>
  #   writer.counts                       # => { entities_created: 412, entities_updated: 0, … }
  class SkeletonWriter
    SOURCE = RailsCodeMap::SOURCE
    PART_OF = "part_of"
    DEFINED_AT = GraphifyRescan::PROVENANCE_PATTERN
    GONE_REASON = "no longer in the Rails code map"

    # @return [Hash{String => MemoryEntity}] entry name => entity, after #call
    attr_reader :entities
    # @return [Set<Integer>] the ids of the entities #call created
    attr_reader :created_ids
    # @return [Array<Hash>] `delete_relation` scan_review items
    attr_reader :review_items
    # @return [Array<String>]
    attr_reader :errors

    # @param map [RailsCodeMap::Map]
    # @param root [MemoryEntity] the scanned project's root
    # @param scan_id [String]
    def initialize(map:, root:, scan_id:)
      @map = map
      @root = root
      @scan_id = scan_id
      @entities = {}
      @created_ids = Set.new
      @review_items = []
      @errors = []
      @counts = Hash.new(0)
    end

    # @return [self]
    def call
      @map.entries.each { |entry| write_entry(entry) }
      write_edges
      if retiring?
        retire_gone_entities
        retire_gone_edges
      end
      self
    end

    # @return [Hash{Symbol => Integer}] entities_created, entities_updated, observations_created,
    #   observations_obsoleted, facts_superseded, relations_created
    def counts
      %i[entities_created entities_updated observations_created observations_obsoleted facts_superseded
         relations_created].index_with { |key| @counts[key] }
    end

    private

    def retiring? = @map.complete? && @errors.empty?

    def write_entry(entry)
      counts = @counts.dup
      created = @created_ids.dup
      ActiveRecord::Base.transaction(requires_new: true) do
        entity = entity_for(entry)
        ensure_parent(entity)
        write_facts(entity, entry.facts)
        @entities[entry.name] = entity
      end
    rescue StandardError => e
      # The savepoint undid the rows: undo the counts too.
      @counts = counts
      @created_ids = created
      @entities.delete(entry.name)
      @errors << "Code map: failed to write #{entry.name}: #{e.message}"
    end

    def entity_for(entry)
      entity = MemoryEntity.find_by(name: entry.name, project_id: @root.id)
      return create_entity(entry) unless entity

      updates = {}
      updates[:entity_type] = entry.type if retype?(entity.entity_type, entry.type)
      aliases = union_aliases(entity.aliases, entry.aliases)
      updates[:aliases] = aliases if aliases != entity.aliases.to_s
      if updates.any?
        entity.update!(updates)
        @counts[:entities_updated] += 1
      end
      entity
    end

    def create_entity(entry)
      entity = MemoryEntity.create!(name: entry.name, entity_type: entry.type, project_id: @root.id,
                                    aliases: entry.aliases.join(",").presence)
      @counts[:entities_created] += 1
      @created_ids << entity.id
      entity
    end

    # Specific beats generic: Class/Module become the role (or Class <-> Module, as the code now
    # declares it); a stored role or any other type stays.
    def retype?(stored, incoming)
      stored != incoming && GraphVocabulary::GENERIC_CODE_TYPES.include?(stored) &&
        ImportEntityResolver::CODE_TYPES.include?(incoming)
    end

    def union_aliases(stored, incoming)
      list = stored.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
      incoming.each { |name| list << name unless list.any? { |kept| kept.casecmp?(name) } }
      list.join(",")
    end

    def ensure_parent(entity)
      return if MemoryRelation.exists?(from_entity_id: entity.id, relation_type: PART_OF)

      create_relation(entity, @root, PART_OF)
    end

    def write_facts(entity, desired)
      own = entity.memory_observations.active.where(source: SOURCE).to_a
      active = entity.memory_observations.active.pluck(:content).to_set { |content| content.to_s.strip }
      desired.each do |content|
        next if own.any? { |observation| observation.content == content }

        if (moved = own.find { |observation| same_definition_file?(observation.content, content) })
          moved.supersede!({ content: content }, reason: "moved in its file")
          own.delete(moved)
          @counts[:facts_superseded] += 1
          next
        end
        next if active.include?(content)

        MemoryObservation.create!(memory_entity: entity, content: content, source: SOURCE, confidence: 1.0, perspective: "world")
        @counts[:observations_created] += 1
      end
      own.each { |observation| obsolete(observation) unless desired.include?(observation.content) }
    end

    def same_definition_file?(stored, wanted)
      stored_file = stored.to_s[DEFINED_AT, 1]
      stored_file.present? && stored_file == wanted.to_s[DEFINED_AT, 1]
    end

    def obsolete(observation)
      observation.mark_obsolete!(reason: GONE_REASON)
      @counts[:observations_obsoleted] += 1
    end

    def write_edges
      @map.edges.each do |edge|
        from = @entities[edge.from]
        to = @entities[edge.to]
        next unless from && to

        type = MemoryRelation.canonical_relation_type(edge.relation)
        next if MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id, relation_type: type)

        create_relation(from, to, type)
      rescue StandardError => e
        @errors << "Code map: failed to relate #{edge.from} -> #{edge.to}: #{e.message}"
      end
    end

    def create_relation(from, to, type)
      MemoryRelation.create!(from_entity_id: from.id, to_entity_id: to.id, relation_type: type,
                             properties: { source: SOURCE, scan_id: @scan_id })
      @counts[:relations_created] += 1
    end

    # Own facts of the project's entities the map no longer holds, unless their file was unreadable.
    def retire_gone_entities
      kept_ids = @entities.values.to_set(&:id)
      unreadable = @map.unreadable_files.to_set
      MemoryObservation.active.where(source: SOURCE, memory_entity_id: MemoryEntity.where(project_id: @root.id).select(:id))
                       .where.not(memory_entity_id: kept_ids.to_a).group_by(&:memory_entity_id).each_value do |facts|
        next if facts.any? { |fact| unreadable.include?(fact.content.to_s[DEFINED_AT, 1]) }

        facts.each { |fact| obsolete(fact) }
      end
    end

    # Own relations from the map's entities that the map no longer has: queued, never deleted here.
    def retire_gone_edges
      wanted = @map.edges.to_set do |edge|
        [ @entities[edge.from]&.id, @entities[edge.to]&.id, MemoryRelation.canonical_relation_type(edge.relation) ]
      end
      MemoryRelation.where(from_entity_id: @entities.values.map(&:id))
                    .where("JSON_UNQUOTE(JSON_EXTRACT(properties, '$.source')) = ?", SOURCE)
                    .where.not(relation_type: PART_OF).find_each do |relation|
        next if wanted.include?([ relation.from_entity_id, relation.to_entity_id, relation.relation_type ])

        @review_items << { id: SecureRandom.uuid, kind: "delete_relation", relation_id: relation.id,
                           reason: "Relation #{relation.relation_type} is no longer in the Rails code map" }
      end
    end
  end
end
