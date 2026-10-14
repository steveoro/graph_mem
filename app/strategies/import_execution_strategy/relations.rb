# frozen_string_literal: true

# Relations pass for ImportExecutionStrategy: bulk endpoint resolution,
# edge creation, cross-repo tagging, and AMBIGUOUS / re-point proposal
# collection (extracted for the 500-line rule).
module ImportExecutionStrategy::Relations
  private

  # Apply name+type-addressed relations after the entity tree exists.
  # Edges whose endpoints cannot be resolved are skipped and counted —
  # never fatal — so a partially-resolvable graph still imports cleanly.
  def apply_relations(relations)
    return if relations.blank?

    # One (name, canonical_type) -> id map for every endpoint and one
    # preloaded set of existing triples: a 50k-edge payload cannot afford
    # two find_by + canonicalize + exists? lookups per edge.
    endpoint_ids = resolve_relation_endpoints(relations)
    # Reference endpoints bind per-edge: the referrer's stored edge
    # target wins even when 2+ projects declare the name — the shared
    # (name,type) map cannot express that.
    reference_to_ids = resolve_reference_targets(relations, endpoint_ids)
    existing = preload_existing_relations(relations, endpoint_ids, reference_to_ids)
    # {entity_id => owning project id}: every resolvable endpoint's
    # project stamp (Project roots own themselves), loaded once so the
    # edge loop never queries per pair.
    endpoint_projects = MemoryEntity.where(id: endpoint_ids.values | reference_to_ids.values)
                                    .pluck(:id, :project_id, :entity_type)
                                    .to_h { |id, pid, type| [ id, pid || (type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE ? id : nil) ] }

    Array(relations).each_with_index do |relation, index|
      raw_type = relation["relation_type"] || relation[:relation_type]

      # Relations are cross-cutting edges only: a hierarchical (part_of)
      # entry would silently re-parent an existing entity, since single
      # -parent relations replace the current parent. Tree shape is
      # accepted exclusively through node children — never this pass.
      if RelationSemantics.hierarchical?(raw_type)
        @logger.warn "ImportExecutionStrategy: Rejected hierarchical relation " \
                     "'#{raw_type}' in relations payload"
        @relations_skipped += 1
        next
      end

      from_id = endpoint_ids[endpoint_key(relation["from_name"] || relation[:from_name],
                                          relation["from_type"] || relation[:from_type])]
      to_id = reference_to_ids[index] || endpoint_ids[endpoint_key(relation["to_name"] || relation[:to_name],
                                        relation["to_type"] || relation[:to_type])]

      unless from_id && to_id
        @relations_unresolved += 1
        next
      end

      # Excluded foreign subtrees are left untouched — but only edges
      # whose SOURCE lives inside one: an edge authored by the foreign
      # project's graph.
      if @excluded_entity_ids.include?(from_id)
        @relations_skipped += 1
        next
      end

      # Edges landing in another project are cross-repo bridges by
      # definition now (scoped names made them ordinary) — tagged so the
      # operator can tell local structure from bridging.
      properties = relation["properties"] || relation[:properties] || {}
      from_project = endpoint_projects[from_id]
      to_project = endpoint_projects[to_id]
      cross_repo = from_project != to_project
      if @excluded_entity_ids.include?(to_id) && !cross_repo
        @relations_skipped += 1
        next
      end
      if cross_repo
        @relations_cross_repo += 1
        relation["properties"] = properties.merge("cross_repo" => true)
        relation.delete(:properties)
      end

      # Multi-declarer endpoints: queue one AMBIGUOUS proposal per
      # referencing edge, listing the candidate declarations. The edge
      # itself stays pointed at the shared stub — nothing is rewired
      # unattended. A stored-edge resolution already picked a real
      # declarer for THIS edge: unambiguous, nothing to propose.
      collect_ambiguous_edge_proposal(relation, from_id, to_id) unless reference_to_ids[index]

      # fatal: false — an invalid edge (e.g. out-of-range confidence) is
      # skipped and counted, never allowed to roll back the whole import.
      create_relation_safe(
        from_id,
        to_id,
        raw_type,
        weight: relation["weight"] || relation[:weight],
        confidence: relation["confidence"] || relation[:confidence],
        properties: relation["properties"] || relation[:properties] || {},
        fatal: false,
        seen: existing
      )
    end
  end

  # Maps each distinct (name, canonical entity_type) endpoint pair in the
  # payload to a MemoryEntity id with a single query. Resolution order for
  # a referenced entity (project-scoped names):
  #   1. a declaration inside the importing project;
  #   2. the entity when EXACTLY ONE other project declares that name+type;
  #   3. the global (NULL-project) entity — the unclaimed reference stub.
  # Two or more declaring projects get AMBIGUOUS: the edge still resolves
  # to the global stub when one exists, and the endpoint is remembered so
  # a proposal listing the candidates is queued after the import.
  def resolve_relation_endpoints(relations)
    names = []
    types = []
    Array(relations).each do |relation|
      names << (relation["from_name"] || relation[:from_name])
      names << (relation["to_name"] || relation[:to_name])
      types << (relation["from_type"] || relation[:from_type])
      types << (relation["to_type"] || relation[:to_type])
    end
    # Class↔Module are one family for endpoint resolution: a payload may
    # reference `Foo:Module` while the stored declaration is `Foo:Class`
    # (mixin stubs emit Module; a claim can retype to Class). Fetch both
    # and bucket them under one family key so either spelling resolves.
    canonical_types = types.uniq.map { |type| ImportEntityResolver.canonical_type(type) }.uniq
                           .flat_map { |t| %w[Class Module].include?(t) ? %w[Class Module] : [ t ] }.uniq

    grouped = {}
    MemoryEntity.where(name: names.uniq, entity_type: canonical_types)
                .pluck(:name, :entity_type, :id, :project_id)
                .each do |(name, entity_type, id, project_id)|
      family = %w[Class Module].include?(entity_type) ? "class-module" : entity_type.to_s.downcase
      (grouped[[ name.to_s.downcase, family ]] ||= []) << [ id, project_id ]
    end

    map = {}
    grouped.each do |key, rows|
      own = @import_project_id && rows.find { |(_, pid)| pid == @import_project_id }
      global = rows.find { |(_, pid)| pid.nil? }
      candidates = rows.reject { |(_, pid)| pid.nil? || pid == @import_project_id }
      declarer_ids = candidates.map { |(_, pid)| pid }.uniq

      map[key] =
        if own
          own.first
        elsif declarer_ids.size == 1
          candidates.first.first
        else
          # 0 declarers = plain global/stub; 2+ = ambiguous = stub + proposal.
          (@ambiguous_endpoint_keys ||= {})[key] = candidates.map(&:first) if declarer_ids.size >= 2
          global&.first
        end
    end
    map
  end

  # Per-edge resolution for endpoints the payload marks as references
  # (`endpoint_reference` in the edge's properties): the resolved FROM
  # entity is the real referrer, and its stored edge target wins — an
  # unchanged re-import binds the same target even after a claim or a
  # second declarer. Only a stored-edge hit overrides the shared map:
  # anything else (2+ declarers → stub + proposal) keeps the map's
  # resolution, so AMBIGUOUS proposals still queue.
  # Returns {relation_index => to_entity_id}.
  def resolve_reference_targets(relations, endpoint_ids)
    Array(relations).each_with_index.each_with_object({}) do |(relation, index), overrides|
      props = relation["properties"] || relation[:properties] || {}
      next unless props["endpoint_reference"] == true || props[:endpoint_reference] == true

      raw_type = relation["relation_type"] || relation[:relation_type]
      next if RelationSemantics.hierarchical?(raw_type)

      from_id = endpoint_ids[endpoint_key(relation["from_name"] || relation[:from_name],
                                          relation["from_type"] || relation[:from_type])]
      next unless from_id

      resolved = ImportEntityResolver.stored_reference_target(
        relation["to_name"] || relation[:to_name],
        [ from_id ],
        [ MemoryRelation.canonical_relation_type(raw_type) ]
      )
      overrides[index] = resolved.id if resolved
    end
  end

  def endpoint_key(name, raw_type)
    type = ImportEntityResolver.canonical_type(raw_type).to_s.downcase
    type = "class-module" if %w[class module].include?(type) # Class↔Module family
    [ name.to_s.downcase, type ]
  end

  # All (from_id, to_id, canonical_type) triples the resolvable relations
  # already have in the DB — one query instead of an exists? per edge. The
  # set doubles as the intra-payload dedupe: create_relation_safe adds each

  def preload_existing_relations(relations, endpoint_ids, reference_to_ids = {})
    triples = Array(relations).each_with_index.filter_map do |relation, index|
      raw_type = relation["relation_type"] || relation[:relation_type]
      next if RelationSemantics.hierarchical?(raw_type)

      from_id = endpoint_ids[endpoint_key(relation["from_name"] || relation[:from_name],
                                          relation["from_type"] || relation[:from_type])]
      to_id = reference_to_ids[index] || endpoint_ids[endpoint_key(relation["to_name"] || relation[:to_name],
                                        relation["to_type"] || relation[:to_type])]
      [ from_id, to_id, MemoryRelation.canonical_relation_type(raw_type) ] if from_id && to_id
    end.uniq
    return Set.new if triples.empty?

    # Composite row-value IN matches the (from,to,type) unique index
    # exactly — the old three separate IN lists cross-joined into a
    # superset that pulled unrelated edges. Sliced to keep the SQL under
    # statement-size limits on large payloads.
    seen = Set.new
    triples.each_slice(1_000) do |slice|
      quoted = slice.map do |from_id, to_id, type|
        "(#{from_id.to_i}, #{to_id.to_i}, #{MemoryRelation.connection.quote(type)})"
      end
      MemoryRelation
        .where(Arel.sql("(from_entity_id, to_entity_id, relation_type) IN (#{quoted.join(', ')})"))
        .pluck(:from_entity_id, :to_entity_id, :relation_type)
        .each { |from_id, to_id, type| seen << [ from_id, to_id, type ] }
    end
    seen
  end

  # Create a relation safely (handling duplicates)
  # @param from_entity_id [Integer] Child/source entity ID
  # @param to_entity_id [Integer] Parent/target entity ID
  # @param relation_type [String] Type of relation
  # @param fatal [Boolean] true (tree pass): failures abort the import via
  #   @errors; false (relations pass): failures are counted and skipped so a
  #   single bad edge cannot roll back an otherwise healthy import
  # @param seen [Set, nil] preloaded (from,to,type) triples — membership
  #   replaces the per-edge exists? query and gains the created triples
  def create_relation_safe(from_entity_id, to_entity_id, relation_type, weight: nil, confidence: nil,
                           properties: {}, fatal: true, seen: nil)
    return if from_entity_id == to_entity_id # No self-loops

    canonical_type = MemoryRelation.canonical_relation_type(relation_type)
    triple = [ from_entity_id, to_entity_id, canonical_type ]
    if seen
      return if seen.include?(triple)
    else
      return if MemoryRelation.exists?(from_entity_id: from_entity_id,
                                       to_entity_id: to_entity_id,
                                       relation_type: canonical_type)
    end

    # Hierarchy is single-parent: replace any existing part_of parent before attaching.
    if RelationSemantics.single_parent?(canonical_type)
      MemoryRelation.where(from_entity_id: from_entity_id, relation_type: canonical_type).destroy_all
    end

    RelationSemantics.validate_create!(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: canonical_type
    )

    MemoryRelation.create!(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: canonical_type,
      weight: weight,
      confidence: confidence,
      properties: properties
    )
    @relations_created += 1
    seen&.add(triple)
    @relation_endpoint_ids << from_entity_id << to_entity_id
    @logger.debug "ImportExecutionStrategy: Created relation #{from_entity_id} -[#{canonical_type}]-> #{to_entity_id}"

    # Membership follows every new part_of attach — a reparent moves the
    # entity (and its subtree) into the new parent's project, and a first
    # attach moves an unrooted entity out of the global namespace — EXCEPT
    # the reference_stub park edge: a parked stub is global by design and
    # stays unclaimed (the claim path stamps it via the real edge).
    # ProjectMembership refuses the move on a same-name collision in the
    # target scope.
    stub_edge = properties["reference_stub"] == true || properties[:reference_stub] == true
    if RelationSemantics.single_parent?(canonical_type) && !stub_edge
      ProjectMembership.sync!(MemoryEntity.find_by(id: from_entity_id))
    end
  rescue RelationSemantics::ValidationError, ActiveRecord::RecordInvalid, ProjectMembership::Collision => e
    record_relation_failure(from_entity_id, to_entity_id, e, fatal: fatal)
  end

  def record_relation_failure(from_entity_id, to_entity_id, error, fatal:)
    message = "Failed to create relation (#{from_entity_id} -> #{to_entity_id}): #{error.message}"
    if fatal
      @errors << message
    else
      @logger.warn "ImportExecutionStrategy: #{message} — edge skipped"
      @relations_skipped += 1
    end
  end

  # One AMBIGUOUS proposal per referencing edge whose far endpoint is
  # declared by 2+ projects (recorded by resolve_relation_endpoints). The
  # item lists the candidates; applying it is the operator's re-point call.
  def collect_ambiguous_edge_proposal(relation, from_id, to_id)
    to_name = relation["to_name"] || relation[:to_name]
    candidate_ids = (@ambiguous_endpoint_keys || {})[endpoint_key(to_name, relation["to_type"] || relation[:to_type])]
    return if candidate_ids.blank?

    @extra_ambiguous_relations << {
      "from_id" => from_id,
      "to_id" => to_id,
      "relation_type" => relation["relation_type"] || relation[:relation_type],
      "candidates" => candidate_ids,
      "properties" => (relation["properties"] || relation[:properties] || {}).merge(
        "context" => "#{to_name} is declared by #{candidate_ids.size} projects"
      )
    }
  end

  # Second-declarer re-points: `entity` was just created inside this
  # project while other projects hold same-name+type entities with inbound
  # cross-project edges. Each such edge gets a re-point proposal aimed at
  # the new declaration — nothing is rewired unattended.
  def collect_repoint_proposals(entity)
    # `NOT IN (NULL, x)` excludes every row — peer = same name+type held
    # by another (non-global) project.
    peers = MemoryEntity.where(name: entity.name, entity_type: entity.entity_type)
                        .where.not(project_id: nil)
                        .where.not(project_id: entity.project_id)
    return if peers.empty?

    inbound = MemoryRelation.where(to_entity_id: peers.select(:id))
                            .includes(:from_entity).select do |rel|
      rel.from_entity && rel.from_entity.project_id != rel.to_entity.project_id
    end
    inbound.each do |rel|
      @extra_ambiguous_relations << {
        "from_id" => rel.from_entity_id,
        "to_id" => entity.id,
        "relation_type" => rel.relation_type,
        "candidates" => [ rel.to_entity_id, entity.id ],
        "properties" => { "context" =>
          "#{entity.name} is now declared in project #{entity.project_id} — re-point?" }
      }
    end
  end

  def relation_endpoints(entity_id, parent_id, direction)
    return [ parent_id, entity_id ] if direction == "parent_to_child"

    [ entity_id, parent_id ]
  end
end
