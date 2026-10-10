# frozen_string_literal: true

# A3 incremental rescan: reconciles a previously imported Graphify subtree
# against a fresh translated payload. Split out of GraphifyImporter (which
# stays under the repo's 500-line file-size rule) — the importer only owns
# JSON → import-tree translation; this module owns DB-backed diffing.
#
# Design decisions (reviewed with the maintainer — do not "fix" as
# false positives):
# - A Graphify graph.json is the FULL repository scan by contract.
#   Absence of a previously imported entity or edge means the code was
#   removed, not that it went unscanned — so there is deliberately no
#   coverage heuristic (one would let partial scans nuke whole subtrees).
#   Rescan safety comes from scoping the diff to the root's own `part_of`
#   subtree, never from guessing coverage.
# - Entities and relations are never auto-deleted. Vanished entities only
#   lose their graphify provenance observations (trust decays through the
#   existing machinery) and are queued as `delete_entity` scan_review
#   items; vanished edges become `delete_relation` items (relations have
#   no status column). Same-tree moves become `reparent_entity` items —
#   unattended imports never re-parent, so the operator decides.
# - Provenance drift supersedes (keeps the `superseded_by` chain) rather
#   than obsolete+re-add.
# - A later scan that brings an item back RETIRES its pending delete
#   proposal: applying a stale proposal would delete live data.
module GraphifyRescan
  SOURCE_NAME = GraphifyImporter::SOURCE_NAME

  # Parses `provenance_observation` content ("Defined at <file>[:<line>]")
  # — the marker every rescan diff keys on. Graphify emits locations as
  # "L<digits>" (e.g. source_location "L5" → "Defined at app/x.rb:L5"),
  # while plain ":<digits>" stays supported for hand-written payloads;
  # both capture the line in group 2 so a line-only drift counts as a
  # same-file change.
  PROVENANCE_PATTERN = /\ADefined at (.+?)(?::L?(\d+))?\z/

  # Entities under `root` carrying ≥1 graphify provenance observation — the
  # stored set a rescan diffs against. Empty ⇒ first import, not a rescan.
  # Obsolete/superseded rows intentionally still count: a vanished entity
  # stays in the stored set so a later scan can recognize its return.
  def self.stored_entities(root, source: SOURCE_NAME)
    return MemoryEntity.none unless root

    MemoryEntity
      .where(id: RelationSemantics.descendant_ids(root.id).to_a)
      .joins(:memory_observations)
      .where(memory_observations: { source: source })
      .where("memory_observations.content LIKE ?", "Defined at %")
      .distinct
  end

  # Indexes a translated payload for diffing:
  #   keys:         Set of [entity_type.downcase, name.downcase] per node
  #   obs:          {key => Set["Defined at …"]} provenance contents
  #   tree_parents:      {child_key => parent_key} containment map (roots
  #                      have no entry)
  #   tree_parent_paths: {child_key => parent node_path} — resolves the
  #                      parent through the import's own entity mapping so
  #                      a move proposal never targets a same-named entity
  #                      in another project.
  def self.payload_index(import_data, source: SOURCE_NAME)
    index = { keys: Set.new,
              obs: Hash.new { |hash, key| hash[key] = Set.new },
              tree_parents: {},
              tree_parent_paths: {} }
    walk = lambda do |nodes, parent_key, parent_path|
      Array(nodes).each_with_index do |node, node_index|
        next unless node.is_a?(Hash)

        path = parent_path ? "#{parent_path}.children.#{node_index}" : node_index.to_s
        key = [ (node["entity_type"] || node[:entity_type]).to_s.downcase,
                (node["name"] || node[:name]).to_s.downcase ]
        index[:keys] << key
        if parent_key
          index[:tree_parents][key] ||= parent_key
          index[:tree_parent_paths][key] ||= parent_path
        end
        Array(node["observations"] || node[:observations]).each do |obs|
          next if source.present? && (obs["source"] || obs[:source]) != source

          content = (obs["content"] || obs[:content]).to_s
          index[:obs][key] << content if content.match?(PROVENANCE_PATTERN)
        end
        walk.call(node["children"] || node[:children], key, path)
      end
    end
    walk.call(import_data["root_nodes"] || import_data[:root_nodes], nil, nil)
    index
  end

  # First rescan phase, run INSIDE the import transaction before the tree
  # applies: reconcile stored graphify provenance against the new payload.
  #   absent entity  → every provenance obs obsoleted + entity collected
  #   present entity → obs absent from the payload obsoleted, unless the
  #                    same file has a replacement (then `supersede!`, so
  #                    merge de-dup sees the new content and stays quiet)
  # Returns nil when the subtree holds no graphify entities (first import).
  def self.observation_diff!(root, import_data, source: SOURCE_NAME)
    stored = stored_entities(root, source: source)
    return nil unless stored.exists?

    index = payload_index(import_data, source: source)
    result = { vanished: [], obsoleted: 0, superseded: 0 }

    stored.find_each do |entity|
      key = [ entity.entity_type.to_s.downcase, entity.name.to_s.downcase ]
      present = index[:keys].include?(key)
      new_contents = index[:obs][key]
      replacement_by_file = new_contents.index_by { |c| PROVENANCE_PATTERN.match(c)[1] }

      entity.memory_observations
          .where(status: MemoryObservation::ACTIVE_STATUS, source: source)
          .where("content LIKE ?", "Defined at %")
          .find_each do |obs|
        if !present
          obs.mark_obsolete!(reason: "removed in #{source} rescan")
          result[:obsoleted] += 1
        elsif !new_contents.include?(obs.content)
          replacement = replacement_by_file[PROVENANCE_PATTERN.match(obs.content)[1]]
          if replacement
            obs.supersede!(content: replacement, reason: "moved in #{source} rescan")
            result[:superseded] += 1
          else
            obs.mark_obsolete!(reason: "removed in #{source} rescan")
            result[:obsoleted] += 1
          end
        end
      end

      result[:vanished] << entity unless present
    end
    result
  end

  # Second rescan phase, run AFTER `apply_relations`: stored
  # graphify-sourced edges absent from the new payload — but ONLY when
  # both endpoints are still present (a vanished endpoint is already
  # covered by its delete_entity item). Never auto-deletes.
  def self.relation_diff(import_data, stored_ids, source: SOURCE_NAME)
    return [] if stored_ids.blank?

    index = payload_index(import_data, source: source)
    new_edges = edge_keys(import_data["relations"] || import_data[:relations])

    MemoryRelation
      .where(from_entity_id: stored_ids)
      .where("JSON_UNQUOTE(JSON_EXTRACT(properties, '$.source')) = ?", source)
      .includes(:from_entity, :to_entity)
      .filter_map do |relation|
        from_key = [ relation.from_entity.entity_type.to_s.downcase, relation.from_entity.name.to_s.downcase ]
        to_key = [ relation.to_entity.entity_type.to_s.downcase, relation.to_entity.name.to_s.downcase ]
        next unless index[:keys].include?(from_key) && index[:keys].include?(to_key)
        next if new_edges.include?([ from_key, to_key, relation.relation_type.to_s.downcase ])

        relation
      end
  end

  # Same-tree moves, detected AFTER the tree applied: a stored entity whose
  # `part_of` parent differs from the parent the payload assigns it. The
  # import never re-parents unattended, so each move becomes a
  # `reparent_entity` review item (its apply swaps the parent edge in one
  # transaction). Cross-tree cases stay excluded by the import itself.
  # @return [Array<Hash>] reparent items {entity_id, parent_id, entity_name}
  def self.reparent_diff(import_data, stored_ids, entity_mapping)
    return [] if stored_ids.blank?

    index = payload_index(import_data)
    tree_parents = index[:tree_parents]
    return [] if tree_parents.empty?

    entities = MemoryEntity.where(id: stored_ids).index_by(&:id)
    by_key = entities.values.index_by do |e|
      [ e.entity_type.to_s.downcase, e.name.to_s.downcase ]
    end
    parent_rows = MemoryRelation
                  .where(from_entity_id: entities.keys, relation_type: "part_of")
                  .includes(:to_entity)
                  .group_by(&:from_entity_id)

    tree_parents.filter_map do |child_key, parent_key|
      entity = by_key[child_key]
      next unless entity

      stored_parent_keys = Array(parent_rows[entity.id]).map do |rel|
        [ rel.to_entity.entity_type.to_s.downcase, rel.to_entity.name.to_s.downcase ]
      end
      # Unparented entities take the edge directly via `add_relation` —
      # only a genuinely different stored parent counts as a move.
      next if stored_parent_keys.empty? || stored_parent_keys.include?(parent_key)

      # Resolve the new parent through the import's own node_path →
      # entity mapping: the payload parent may have merged onto a
      # different entity than a global name+type lookup would find, and a
      # same-named entity in another project is never a valid target.
      parent_path = index[:tree_parent_paths][child_key]
      new_parent_id = entity_mapping[parent_path]
      next unless new_parent_id

      { entity_id: entity.id, parent_id: new_parent_id, entity_name: entity.name }
    end
  end

  # Queues vanished entities/edges (and same-tree moves) as one-click
  # proposals under scan_review — operator applies, nothing auto-deletes.
  # Items already pending (same signature) are skipped BEFORE creating the
  # MaintenanceReport, so a re-run with no new findings leaves no empty
  # report behind. Newer reparent proposals retire older pending ones for
  # the same entity, so conflicting moves never coexist.
  # @param entities  [Array<MemoryEntity>] → delete_entity items
  # @param relations [Array<MemoryRelation>] → delete_relation items
  # @param reparents [Array<Hash>] {entity_id, parent_id} → reparent_entity
  # @return [Array<MaintenanceReportRow>] the rows actually created
  def self.seed_review(entities:, relations:, reparents: [], source_ref:, source: SOURCE_NAME)
    items = build_review_items(entities: entities, relations: relations, reparents: reparents,
                               source: source)
    fresh_items = fresh_review_items(items)
    retire_superseded_reparents(fresh_items)
    return [] if fresh_items.empty?

    CompactionReviewService.seed_report(
      report_type: "scan_review",
      source: source,
      source_ref: source_ref,
      items: fresh_items
    )
  end

  # Proposal items in FLAT shape — the review form reads top-level payload
  # keys (`payload["entity_id"]` etc.), so nesting under "payload" would
  # render blank targets. `signature_for` digs flat-then-nested, so the
  # signatures match either shape.
  def self.build_review_items(entities:, relations:, reparents:, source: SOURCE_NAME)
    operator_counts = MemoryObservation.active
                                       .where(memory_entity_id: entities.map(&:id))
                                       .where.not(source: source)
                                       .group(:memory_entity_id).count
    items = entities.map do |entity|
      operator_obs = operator_counts[entity.id].to_i
      reason = "removed in #{source} rescan"
      reason += " — still has #{operator_obs} active non-graphify observation#{'s' if operator_obs != 1}" if operator_obs.positive?
      {
        kind: "delete_entity",
        entity_id: entity.id,
        entity_name: entity.name,
        entity_type: entity.entity_type,
        reason: reason
      }
    end
    items += relations.map do |relation|
      { kind: "delete_relation", relation_id: relation.id, reason: "removed in graphify rescan" }
    end
    items + reparents.map do |reparent|
      { kind: "reparent_entity", entity_id: reparent[:entity_id],
        parent_id: reparent[:parent_id], reason: "moved in graphify rescan" }
    end
  end
  private_class_method :build_review_items

  # Skip items whose signature already sits pending or suppressed —
  # identical to seed_report's dedupe, but BEFORE an empty report exists.
  def self.fresh_review_items(items)
    signatures = items.index_with do |item|
      CompactionReviewService.signature_for(item[:kind], item.except(:id))
    end
    pending_signatures = MaintenanceReportRow.by_report_type("scan_review").pending
                                           .where(signature: signatures.values.compact)
                                           .pluck(:signature).to_set
    items.reject do |item|
      signature = signatures[item]
      signature.blank? || pending_signatures.include?(signature) ||
        MaintenanceReportSuppression.suppressed?("scan_review", signature)
    end
  end
  private_class_method :fresh_review_items

  # A FRESH reparent proposal retires older ACTIVE reparent rows for the
  # same entity — the latest scan wins. Runs after dedupe so an identical
  # re-scan neither dismisses nor re-seeds (it re-reported forever and
  # clobbered an operator's "ignored" decision in Graphy's probe).
  def self.retire_superseded_reparents(fresh_items)
    fresh_reparent_ids = fresh_items.select { |i| i[:kind] == "reparent_entity" }
                                    .map { |i| i[:entity_id] }
    return if fresh_reparent_ids.empty?

    graphify_review_rows.each do |row|
      next unless row.kind == "reparent_entity" && row.status == "active"
      next unless fresh_reparent_ids.include?(item_field(row, "entity_id").to_i)

      row.update!(status: "dismissed", dismissed_at: Time.current,
                  resolution_reason: "superseded by a newer graphify rescan proposal")
    end
  end
  private_class_method :retire_superseded_reparents

  # Retires stale proposals. A pending item is stale when the current scan
  # contradicts it — the invariant: no proposal may stay apply-able to live
  # data the latest graph.json does not support. Only rows from
  # graphify-seeded reports are touched (another scanner's queue is its own).
  #   delete_entity/delete_relation — target is PRESENT again (restored)
  #   reparent_entity              — entity gone from the payload, the
  #                                  payload now assigns a different parent
  #                                  than the proposal, or the stored parent
  #                                  already matches (move already satisfied)
  def self.dismiss_restored_items(stored_ids:, import_data:, entity_mapping: {}, source: SOURCE_NAME)
    return if stored_ids.blank?

    index = payload_index(import_data, source: source)
    tree_parent_paths = index[:tree_parent_paths]
    new_edges = edge_keys(import_data["relations"] || import_data[:relations])
    stored = MemoryEntity.where(id: stored_ids).to_a
    present_ids = stored.filter_map { |e| e.id if index[:keys].include?(entity_key(e)) }.to_set

    rows = graphify_review_rows(source: source).to_a
    relation_rows = rows.select { |r| r.kind == "delete_relation" }
    reparent_rows = rows.select { |r| r.kind == "reparent_entity" }

    # Batch loads (one query each instead of per-row lookups).
    relations = MemoryRelation.where(id: relation_rows.map { |r| item_field(r, "relation_id") })
                              .includes(:from_entity, :to_entity)
                              .index_by(&:id)
    rep_entity_ids = (reparent_rows.map { |r| item_field(r, "entity_id") } +
                      reparent_rows.map { |r| item_field(r, "parent_id") }).compact.uniq
    rep_entities = MemoryEntity.where(id: rep_entity_ids).index_by(&:id)
    rep_stored_parents = MemoryRelation.where(from_entity_id: reparent_rows.map { |r| item_field(r, "entity_id") },
                                              relation_type: "part_of")
                                       .includes(:to_entity)
                                       .group_by(&:from_entity_id)

    rows.each do |row|
      stale = case row.kind
      when "delete_entity"
                present_ids.include?(item_field(row, "entity_id").to_i)
      when "delete_relation"
                relation = relations[item_field(row, "relation_id").to_i]
                if relation && stored_ids.include?(relation.from_entity_id)
                  triple = [ entity_key(relation.from_entity), entity_key(relation.to_entity),
                             relation.relation_type.to_s.downcase ]
                  new_edges.include?(triple)
                end
      when "reparent_entity"
                entity = rep_entities[item_field(row, "entity_id").to_i]
                # Rows about entities outside this scan's subtree belong
                # to another project's queue and are left alone. A missing
                # entity (deleted) can never apply anywhere, so ANY
                # project's rescan retires the row — that is intentional:
                # the proposal is permanently unapplyable regardless of
                # which subtree it once belonged to.
                next if entity && !stored_ids.include?(entity.id)

                parent = rep_entities[item_field(row, "parent_id").to_i]
                reparent_row_stale?(entity, parent, present_ids, tree_parent_paths,
                                    rep_stored_parents, entity_mapping)
      end
      next unless stale

      row.update!(status: "dismissed", dismissed_at: Time.current,
                  resolution_reason: "stale in #{source} rescan")
    end
  end

  # The pending review rows this scanner owns — scoped by the report's
  # `data.source` so proposals seeded by other scanners stay untouched.
  def self.graphify_review_rows(source: SOURCE_NAME)
    MaintenanceReportRow.by_report_type("scan_review").pending
                        .joins(:maintenance_report)
                        .where("JSON_UNQUOTE(JSON_EXTRACT(maintenance_reports.data, '$.source')) = ?", source)
  end
  private_class_method :graphify_review_rows

  # A reparent proposal stays valid only while all of these hold:
  # the entity is still in the payload, the payload still asks for this
  # exact parent (compared by resolved entity id — the parent node may
  # merge onto a differently-named entity, so name keys are not enough),
  # and the stored parent edge has not caught up yet.
  # The caller scopes rows to this scan's subtree first; a missing entity
  # here means it was deleted → the proposal can never apply → stale.
  def self.reparent_row_stale?(entity, parent, present_ids, tree_parent_paths,
                               rep_stored_parents, entity_mapping)
    return true unless entity && parent
    return true unless present_ids.include?(entity.id)

    resolved_parent_id = entity_mapping[tree_parent_paths[entity_key(entity)]]
    return true if resolved_parent_id && resolved_parent_id != parent.id
    return false if resolved_parent_id.nil? # payload parent unresolved → cannot verify → keep

    Array(rep_stored_parents[entity.id]).map(&:to_entity_id).include?(resolved_parent_id)
  end
  private_class_method :reparent_row_stale?

  def self.entity_key(entity)
    [ entity.entity_type.to_s.downcase, entity.name.to_s.downcase ]
  end
  private_class_method :entity_key

  # Seeded rows nest ids under "payload"; hand-seeded ones keep them flat.
  def self.item_field(row, field)
    row.effective_payload.dig("payload", field) || row.effective_payload[field]
  end
  private_class_method :item_field

  # (from_key, to_key, canonical_type) triples the payload asserts — used
  # both to diff stored edges and to recognize restored ones.
  def self.edge_keys(relations)
    Array(relations).each_with_object(Set.new) do |rel, set|
      next unless rel.is_a?(Hash)

      from_key = [ (rel["from_type"] || rel[:from_type]).to_s.downcase,
                   (rel["from_name"] || rel[:from_name]).to_s.downcase ]
      to_key = [ (rel["to_type"] || rel[:to_type]).to_s.downcase,
                 (rel["to_name"] || rel[:to_name]).to_s.downcase ]
      set << [ from_key, to_key,
               MemoryRelation.canonical_relation_type(rel["relation_type"] || rel[:relation_type]).to_s.downcase ]
    end
  end
end
