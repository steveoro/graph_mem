# frozen_string_literal: true

# Strategy class for executing the data import based on operator decisions
#
# This strategy:
# - Processes match results with operator selections
# - Creates new entities or merges into existing ones
# - Handles child node actions: skip, add_relation, create
# - Transfers observations and creates relations
# - Wraps everything in a transaction for atomicity
# - Returns detailed report of the import operation
class ImportExecutionStrategy
  # Result struct for import report
  ImportReport = Struct.new(
    :success,
    :entities_created,
    :entities_merged,
    :entities_skipped,
    :observations_created,
    :observations_obsoleted,
    :observations_superseded,
    :relations_created,
    :relations_unresolved,
    :relations_skipped,
    :relations_cross_repo,
    :rescan,
    :rescan_entities_flagged,
    :rescan_relations_flagged,
    :rescan_reparents_flagged,
    :errors,
    keyword_init: true
  ) do
    def to_h
      {
        success: success,
        entities_created: entities_created,
        entities_merged: entities_merged,
        entities_skipped: entities_skipped,
        observations_created: observations_created,
        observations_obsoleted: observations_obsoleted,
        observations_superseded: observations_superseded,
        relations_created: relations_created,
        relations_unresolved: relations_unresolved,
        relations_skipped: relations_skipped,
        relations_cross_repo: relations_cross_repo,
        rescan: rescan,
        rescan_entities_flagged: rescan_entities_flagged,
        rescan_relations_flagged: rescan_relations_flagged,
        rescan_reparents_flagged: rescan_reparents_flagged,
        errors: errors
      }
    end
  end

  def initialize(progress_tracker: nil, observation_duplicate_detector: ImportObservationDuplicateDetector.new)
    @logger = Rails.logger
    @progress_tracker = progress_tracker
    @observation_duplicate_detector = observation_duplicate_detector
    @entities_created = 0
    @entities_merged = 0
    @entities_skipped = 0
    @observations_created = 0
    @observations_obsoleted = 0
    @observations_superseded = 0
    @relations_created = 0
    @relations_unresolved = 0
    @relations_skipped = 0
    @relations_cross_repo = 0
    @rescan_active = false
    @rescan_vanished_entities = []
    @rescan_vanished_relations = []
    @rescan_reparents = []
    @rescan_entities_flagged = 0
    @rescan_relations_flagged = 0
    @rescan_reparents_flagged = 0
    @errors = []
    @entity_mapping = {} # Maps import node paths to created/matched entity IDs
    @relation_endpoint_ids = Set.new # endpoints of every relation created
    @excluded_entity_ids = Set.new # entities inside excluded foreign subtrees
    # Project scope of THIS import: the Project entity the root node merged
    # into or created. Members are created/looked up inside it; NULL means
    # a global import (no Project root). Set on first Project-root mapping.
    @import_project_id = nil
    # Edges whose endpoint name is declared by 2+ projects resolve to the
    # global stub (or stay unresolved) and queue one AMBIGUOUS proposal
    # each; entities a second project declares after edges already point
    # at the first declarer queue "re-point?" proposals. Seeded by the
    # caller alongside payload AMBIGUOUS edges once the import succeeded.
    @extra_ambiguous_relations = []
  end

  # Edges + proposal payloads detected during execution (ambiguous
  # multi-declarer endpoints, second-declarer re-point suggestions). Read
  # after #execute; seeded through GraphifyImporter.seed_ambiguous_relations.
  attr_reader :extra_ambiguous_relations

  # Execute the import based on operator decisions
  # @param import_data [Hash] Original parsed import JSON
  # @param decisions [Array<Hash>] Operator decisions for each node
  #   Each decision has: { node_path:, action:, child_action:, target_id:, parent_id: }
  # @return [ImportReport] Report of the import operation
  def execute(import_data, decisions)
    @logger.info "ImportExecutionStrategy: Starting import execution"

    # Build decision lookup by node path
    decision_map = decisions.index_by { |d| d[:node_path] || d["node_path"] }
    initialize_progress!(import_data)

    # Bulk imports cannot afford a synchronous embedding call and a
    # per-endpoint trust-score recompute per row/edge (measured: ~1.5M
    # queries and 20k embed calls on a 50k-edge graph). Both callbacks are
    # suppressed for the transaction; after it, embeddings are delegated to
    # the maintenance backfill and trust scores are recomputed once per
    # touched entity.
    MemoryRelation.suppress_trust_recompute do
      EmbeddingService.suppress_inline_embeddings do
        # The named embeddings lock serializes this transaction with a running
        # EmbeddingService.backfill_all (which skips its run while the lock is
        # held). Acquired best-effort: if a backfill already holds it we still
        # proceed — store_vector's compare-and-set prevents stale overwrites.
        EmbeddingService.with_embedding_lock(5) do |acquired|
          unless acquired
            @logger.warn "ImportExecutionStrategy: embeddings lock busy; " \
                         "proceeding (store_vector compare-and-set keeps vectors consistent)"
          end

          ActiveRecord::Base.transaction do
            root_nodes = import_data["root_nodes"] || import_data[:root_nodes] || []

            # A3 rescan: Graphify payloads carry "rescan" — when the root's
            # subtree already holds graphify-sourced entities this run is a
            # re-scan, so reconcile stored provenance BEFORE the merge adds
            # new observations (keeps supersede/dedup clean), inside the same
            # transaction. See GraphifyRescan's design-decision comment.
            rescan_root = rescan_root_entity(import_data, decision_map) if import_data["rescan"] || import_data[:rescan]
            if rescan_root
              # The producer that owns the stored facts this rescan diffs:
              # "rescan" => "rails_ast_extractor" diffs only that producer's
              # provenance/edges (graphify's buckets stay untouched).
              @rescan_source = rescan_source(import_data)
              diff = GraphifyRescan.observation_diff!(rescan_root, import_data, source: @rescan_source)
              if diff
                @rescan_active = true
                @observations_obsoleted = diff[:obsoleted]
                @observations_superseded = diff[:superseded]
                @rescan_vanished_entities = diff[:vanished]
                @rescan_stored_ids = GraphifyRescan.stored_entities(rescan_root, source: @rescan_source).pluck(:id)
              end
            end

            root_nodes.each_with_index do |root_node, index|
              path = index.to_s
              decision = decision_map[path]
              parent_id = resolve_parent_id(decision, path)

              process_node_recursive(root_node, path, decision_map, parent_id, nil)
            end

            # Non-tree edges (e.g. code-structure `calls`/`inherits` imported from
            # Graphify) apply after every entity exists: endpoints are addressed by
            # name+type and resolved through the same canonicalization as nodes.
            apply_relations(import_data["relations"] || import_data[:relations])

            # Rescan phase 2: with all edges applied, stored graphify edges
            # absent from the payload are collected for review — never
            # auto-deleted (relations have no status column) — along with
            # same-tree moves (reparent_entity proposals: unattended imports
            # never re-parent, so the operator applies the move).
            if @rescan_active
              @rescan_vanished_relations = GraphifyRescan.relation_diff(
                import_data, @rescan_stored_ids, source: @rescan_source
              )
              @rescan_reparents = GraphifyRescan.reparent_diff(
                import_data, @rescan_stored_ids, @entity_mapping
              )
            end

            raise ActiveRecord::Rollback if @errors.any?
          end
        end
      end
    end

    recompute_trust_for_touched_entities

    @progress_tracker&.complete!(message: "Import completed", counters: progress_counters)

    # Vanished entities/edges (and same-tree moves) become one-click
    # scan_review proposals only after the import succeeded — same rule as
    # ambiguous-edge seeding. A proposal whose target this scan brought
    # BACK is retired at the same time, so a stale delete item can never
    # be applied to live data.
    if @errors.empty? && @rescan_active
      if @rescan_vanished_entities.any? || @rescan_vanished_relations.any? || @rescan_reparents.any?
        # Flagged counts cover NEW proposals only: re-runs whose items are
        # already pending dedupe to zero instead of re-reporting the same
        # flags forever.
        seeded_rows = GraphifyRescan.seed_review(
          entities: @rescan_vanished_entities,
          relations: @rescan_vanished_relations,
          reparents: @rescan_reparents,
          source_ref: rescan_source_ref(import_data),
          source: @rescan_source
        )
        @rescan_entities_flagged = seeded_rows.count { |row| row.kind == "delete_entity" }
        @rescan_relations_flagged = seeded_rows.count { |row| row.kind == "delete_relation" }
        @rescan_reparents_flagged = seeded_rows.count { |row| row.kind == "reparent_entity" }
      end
      GraphifyRescan.dismiss_restored_items(stored_ids: @rescan_stored_ids, import_data: import_data,
                                            entity_mapping: @entity_mapping, source: @rescan_source)
    end

    # Multi-declarer endpoints and second-declarer re-points detected while
    # resolving edges/entities land in scan_review like payload AMBIGUOUS
    # edges — seeded only on success so ids resolve to committed entities.
    if @errors.empty? && @extra_ambiguous_relations.any?
      GraphifyImporter.seed_ambiguous_relations(
        @extra_ambiguous_relations,
        rescan_source_ref(import_data),
        source: GraphifyImporter::KNOWN_PRODUCERS.include?(import_data[:producer].to_s) ?
                import_data[:producer].to_s : @rescan_source || "graphify",
        project_id: @import_project_id
      )
    end

    report = ImportReport.new(
      success: @errors.empty?,
      entities_created: @entities_created,
      entities_merged: @entities_merged,
      entities_skipped: @entities_skipped,
      observations_created: @observations_created,
      # Rescan fields are gated on success: on the ActiveRecord::Rollback
      # path the diff mutations rolled back with the transaction and no
      # review items were seeded — a failed import reports none of it.
      observations_obsoleted: @errors.empty? ? @observations_obsoleted : 0,
      observations_superseded: @errors.empty? ? @observations_superseded : 0,
      relations_created: @relations_created,
      relations_unresolved: @relations_unresolved,
      relations_skipped: @relations_skipped,
      relations_cross_repo: @relations_cross_repo,
      rescan: @errors.empty? && @rescan_active,
      rescan_entities_flagged: @rescan_entities_flagged,
      rescan_relations_flagged: @rescan_relations_flagged,
      rescan_reparents_flagged: @rescan_reparents_flagged,
      errors: @errors
    )
    enqueue_embedding_backfill if report.success
    report
  rescue ImportObservationDuplicateDetector::UnavailableError => e
    @logger.error "ImportExecutionStrategy: Semantic observation de-duplication unavailable: #{e.message}"
    @errors << "Semantic observation de-duplication unavailable: #{e.message}"
    @progress_tracker&.fail!(e)

    failed_report
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
    @logger.error "ImportExecutionStrategy: Transaction failed: #{e.message}"
    @errors << "Transaction failed: #{e.message}"

    @progress_tracker&.fail!(e)

    failed_report
  end

  include ImportExecutionStrategy::Claims
  include ImportExecutionStrategy::Relations
  include ImportExecutionStrategy::Reporting
  include ImportExecutionStrategy::EntityWrites

  private

  # Process a node and its children recursively
  # @param node [Hash] The import node data
  # @param path [String] Path in the import tree
  # @param decision_map [Hash] Map of node paths to decisions
  # @param parent_entity_id [Integer, nil] Parent entity ID for root imports
  # @param tree_parent_id [Integer, nil] Parent entity ID from tree traversal
  def process_node_recursive(node, path, decision_map, parent_entity_id, tree_parent_id)
    decision = decision_map[path]

    # Determine the action - check child_action first, then action
    child_action = decision&.dig(:child_action) || decision&.dig("child_action")
    action = decision&.dig(:action) || decision&.dig("action") || "create"
    target_id = decision&.dig(:target_id) || decision&.dig("target_id")

    # Determine which action to take
    effective_action = child_action || action

    # Process this node based on action. `referrer_id` = the payload parent
    # the node sits under — reference nodes use it to resolve the entity
    # their stored edge already points at.
    referrer_id = tree_parent_id || parent_entity_id
    entity_id = case effective_action
    when "skip"
      handle_skip_action(node, referrer_id)
    when "exclude"
      handle_exclude_action(node)
    when "add_relation"
      handle_add_relation_action(node, tree_parent_id)
    when "merge"
      merge_into_existing(node, target_id)
    else
      create_new_entity(node, referrer_id: referrer_id)
    end

    unless entity_id
      @progress_tracker&.increment!(message: "Processed import node #{path}", counters: progress_counters)
      return
    end

    # Store the mapping for child processing
    @entity_mapping[path] = entity_id

    # The first Project-typed root that maps is THIS import's project scope:
    # every subsequent member create/lookup happens inside it.
    if @import_project_id.nil? && !path.include?(".") &&
       ImportEntityResolver.canonical_type(node[:entity_type] || node["entity_type"]) == "Project"
      @import_project_id = entity_id
    end

    # Create relation to parent (either explicit parent_entity_id or tree parent)
    # Skip for "skip" action as the relation already exists
    unless effective_action == "skip"
      actual_parent_id = parent_entity_id || tree_parent_id
      if actual_parent_id.present? && actual_parent_id != entity_id
        relation_type = node[:relation_type] || node["relation_type"] || "part_of"
        relation_direction = node[:relation_direction] || node["relation_direction"]
        from_entity_id, to_entity_id = relation_endpoints(
          entity_id,
          actual_parent_id,
          relation_direction
        )
        create_relation_safe(
          from_entity_id,
          to_entity_id,
          relation_type,
          weight: node[:relation_weight] || node["relation_weight"],
          confidence: node[:relation_confidence] || node["relation_confidence"],
          properties: node[:relation_properties] || node["relation_properties"] || {}
        )
      end
    end

    # Process children
    children = node["children"] || node[:children] || []
    children.each_with_index do |child, index|
      child_path = "#{path}.children.#{index}"
      # Children inherit this entity as their tree parent
      process_node_recursive(child, child_path, decision_map, nil, entity_id)
    end

    @progress_tracker&.increment!(message: "Processed import node #{path}", counters: progress_counters)
  end

  def resolve_parent_id(decision, path)
    explicit_parent = decision&.dig(:parent_id) || decision&.dig("parent_id")
    return explicit_parent if explicit_parent.present?

    parent_path = decision&.dig(:parent_path) || decision&.dig("parent_path")
    return @entity_mapping[parent_path] if parent_path.present?

    nil
  end
end
