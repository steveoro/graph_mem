# frozen_string_literal: true

class GraphifyImporter
  # Headless-import decision + reference-stub helpers extracted from
  # GraphifyImporter to keep both files under the 500-line rule. Extended
  # into the class, so GraphifyImporter.seed_ambiguous_relations,
  # GraphifyImporter.headless_decisions & friends keep their call sites.
  module Matching
  def seed_ambiguous_relations(ambiguous, source_ref)
    return [] if ambiguous.blank?

    items = ambiguous.filter_map do |relation|
      from = ImportEntityResolver.find_by_name_and_type(relation["from_name"], relation["from_type"])
      to = ImportEntityResolver.find_by_name_and_type(relation["to_name"], relation["to_type"])
      next unless from && to
      next if from.id == to.id
      next if MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id,
                                     relation_type: relation["relation_type"])

      props = relation["properties"] || {}
      location = [ props["source_file"], props["source_location"] ].compact_blank.join(":")
      {
        id: SecureRandom.uuid,
        kind: "relationship_proposal",
        from_entity_id: from.id,
        from_name: from.name,
        from_entity_type: from.entity_type,
        to_entity_id: to.id,
        to_name: to.name,
        to_entity_type: to.entity_type,
        relation_type: relation["relation_type"],
        confidence_band: "low",
        score: (relation["confidence"].to_f * 10).round,
        supporting_observation_ids: [],
        explanation: "Graphify AMBIGUOUS edge in #{location}",
        evidence_terms: [ props["context"] ].compact
      }
    end
    return [] if items.empty?

    CompactionReviewService.seed_report(
      report_type: "scan_review",
      source: SOURCE_NAME,
      source_ref: source_ref,
      items: items
    )
  end


  # Auto-accept decision map for headless imports. Mirrors operator review:
  # children take the matcher-suggested action — except `add_relation` on a
  # child that already has a `part_of` parent, which would silently steal the
  # entity from another project's tree — and roots merge ONLY on an exact
  # name+type match: the matcher's `selected_match_id` comes from a fuzzy
  # text search on "<name> <type>" and routinely resolves to an unrelated
  # Project (the type word alone matches any project named "… Project"),
  # so it is never trusted unattended.
  # Unattended imports never re-parent. Operators keep full re-parent rights
  # through explicit Import Review decisions.
  # @param match_results [Array<ImportMatchingStrategy::MatchResult>]
  # @return [Array<Hash>] decisions for ImportExecutionStrategy#execute
  def headless_decisions(match_results)
    by_path = match_results.index_by(&:node_path)
    # Stub detection is batched once per import: one query for stub-tagged
    # part_of edges + one for provenance obs, instead of per-entity N+1.
    stub_ids = reference_stub_ids(match_results.filter_map(&:exact_match))
    foreign_paths = foreign_subtree_paths(match_results, by_path, stub_ids)

    match_results.map do |match|
      if match.is_child
        child_action = match.child_action
        if already_parented?(match.exact_match) && stub_ids.include?(match.exact_match&.id) &&
           match.import_node[:reference] != true
          # Claiming an unclaimed stub — but ONLY when this payload actually
          # declares the node. `add_relation` replaces the stub-tagged
          # part_of edge with the declaring tree's parent (part_of is
          # single-parent), so the referencing repo's rescan can no longer
          # diff the declaring repo's facts as its own. A payload that only
          # *references* the stub too keeps the stored parent (skip):
          # otherwise two referencing repos would ping-pong the edge on
          # every alternating import.
          child_action = "add_relation"
        elsif child_action == "add_relation" && already_parented?(match.exact_match)
          child_action = "skip"
        end
        # A child parented under a DIFFERENT entity than this import's parent
        # node belongs to another project's tree: exclude it AND its whole
        # subtree. `exclude` is a counted no-op — `skip` would still create
        # the entity when it is missing (handle_skip_action's create
        # fallback), leaving orphans with no `part_of` parent.
        child_action = "exclude" if inside_any?(match.node_path, foreign_paths)
        { node_path: match.node_path, child_action: child_action }
      else
        exact = exact_root_match(match)
        if exact
          { node_path: match.node_path, action: "merge", target_id: exact.id }
        else
          { node_path: match.node_path, action: "create" }
        end
      end
    end
  end

  # The entity a root node would merge into, if it exists: exact name +
  # canonical type lookup (case-insensitive under the utf8mb4 collation).
  # @return [MemoryEntity, nil]
  def exact_root_match(match)
    node = match.import_node || {}
    ImportEntityResolver.find_by_name_and_type(node[:name] || node["name"],
                                               node[:entity_type] || node["entity_type"])
  end
  private :exact_root_match

  def already_parented?(entity)
    entity.present? && MemoryRelation.exists?(from_entity_id: entity.id, relation_type: "part_of")
  end
  private :already_parented?

  # Paths of children whose matched entity already has a `part_of` parent
  # that is NOT the entity this import would attach under (when the import
  # parent resolves to a different entity — or creates a fresh one — the
  # match's real parent belongs to another tree).
  def foreign_subtree_paths(match_results, by_path, stub_ids = nil)
    root_match = match_results.find { |m| !m.is_child }
    root_id = (exact_root_match(root_match)&.id if root_match)
    same_tree_ids = nil
    stub_ids ||= reference_stub_ids(match_results.filter_map(&:exact_match))

    match_results.each_with_object(Set.new) do |match, foreign|
      next unless match.is_child && already_parented?(match.exact_match)

      # An entity with NO active producer provenance is an unclaimed
      # reference stub (an earlier import emitted it as a dangling edge
      # target): whichever repo actually declares it gets to claim it —
      # cross-repo order must not decide ownership.
      next if stub_ids.include?(match.exact_match&.id)

      parent_path = match.node_path.sub(/\.children\.\d+\z/, "")
      parent_match = by_path[parent_path]
      # The entity this import would attach the child under: the parent's own
      # exact match when the parent is a child node, or the root's exact
      # name+type match (never the fuzzy selected_match_id) for root-level
      # children. A root that will be created fresh has no entity yet — every
      # already-parented child of it is foreign.
      expected_id = if parent_match&.is_child
                      parent_match&.exact_match&.id
      elsif parent_match
                      exact_root_match(parent_match)&.id
      end
      actual_id = MemoryRelation.where(from_entity_id: match.exact_match.id,
                                       relation_type: "part_of").pick(:to_entity_id)
      next if expected_id.present? && expected_id == actual_id

      # The child MOVED inside the same project tree when its real parent is
      # still under this root's part_of subtree — not a foreign subtree.
      # Excluding it would drop its new provenance (A3 rescan just obsoleted
      # the old one); `skip` keeps it importable and the rescan diff queues
      # a `reparent_entity` item so the operator can apply the move.
      same_tree_ids ||=
        if root_id
          Set.new([ root_id ]).merge(RelationSemantics.descendant_ids(root_id).to_a)
        else
          Set.new
        end
      foreign << match.node_path unless same_tree_ids.include?(actual_id)
    end
  end
  private :foreign_subtree_paths

  # True when `path` equals or descends from any path in `ancestors`
  # (descendants look like "<path>.children.N[.children.M...]").
  def inside_any?(path, ancestors)
    return false if ancestors.empty?

    current = path
    while (idx = current.rindex(".children."))
      return true if ancestors.include?(current)
      current = current[0...idx]
    end
    ancestors.include?(current)
  end
  private :inside_any?

  # Ids of entities that are unclaimed reference stubs: they carry a
  # stub-tagged `part_of` edge (emitted as a dangling edge target by an
  # earlier import) AND no active producer provenance (`Defined at …`).
  # An operator-created entity with no obs is NOT a stub — its foreign
  # subtree keeps the old exclusion behavior.
  def reference_stub_ids(entities)
    ids = entities.filter_map(&:id)
    return Set.new if ids.empty?

    stubbed = MemoryRelation.where(from_entity_id: ids, relation_type: "part_of")
      .where("JSON_UNQUOTE(JSON_EXTRACT(properties, '$.reference_stub')) = 'true'")
      .distinct.pluck(:from_entity_id).to_set
    return Set.new if stubbed.empty?

    with_prov = MemoryObservation.where(memory_entity_id: stubbed.to_a,
                                        status: MemoryObservation::ACTIVE_STATUS)
      .where("content LIKE ?", "Defined at %")
      .distinct.pluck(:memory_entity_id).to_set
    stubbed - with_prov
  end
  private :reference_stub_ids
  end
end
