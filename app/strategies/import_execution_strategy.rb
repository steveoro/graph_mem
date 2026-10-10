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
  end

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
              diff = GraphifyRescan.observation_diff!(rescan_root, import_data)
              if diff
                @rescan_active = true
                @observations_obsoleted = diff[:obsoleted]
                @observations_superseded = diff[:superseded]
                @rescan_vanished_entities = diff[:vanished]
                @rescan_stored_ids = GraphifyRescan.stored_entities(rescan_root).pluck(:id)
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
                import_data, @rescan_stored_ids
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
          source_ref: rescan_source_ref(import_data)
        )
        @rescan_entities_flagged = seeded_rows.count { |row| row.kind == "delete_entity" }
        @rescan_relations_flagged = seeded_rows.count { |row| row.kind == "delete_relation" }
        @rescan_reparents_flagged = seeded_rows.count { |row| row.kind == "reparent_entity" }
      end
      GraphifyRescan.dismiss_restored_items(stored_ids: @rescan_stored_ids, import_data: import_data)
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

  # Deferred counterparts of the suppressed callbacks.
  def recompute_trust_for_touched_entities
    @relation_endpoint_ids.each do |entity_id|
      MemoryObservation
        .where(memory_entity_id: entity_id, status: MemoryObservation::ACTIVE_STATUS)
        .find_each do |observation|
          observation.update_column(:trust_score, ObservationTrustRanker.rank(observation))
        end
    end
  end

  def enqueue_embedding_backfill
    # Merges count too: an alias-only merge clears embedded_at via
    # before_update but creates nothing, so without this the entity silently
    # drops out of vector search until an unrelated backfill runs.
    return unless @entities_created.positive? || @observations_created.positive? ||
                  @entities_merged.positive?

    EmbeddingsMaintenanceEnqueuer.enqueue!("backfill")
  rescue StandardError => e
    @logger.warn "ImportExecutionStrategy: Could not enqueue embedding backfill: #{e.message}"
  end

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

    # Process this node based on action
    entity_id = case effective_action
    when "skip"
      handle_skip_action(node)
    when "exclude"
      handle_exclude_action(node)
    when "add_relation"
      handle_add_relation_action(node, tree_parent_id)
    when "merge"
      merge_into_existing(node, target_id)
    else
      create_new_entity(node)
    end

    unless entity_id
      @progress_tracker&.increment!(message: "Processed import node #{path}", counters: progress_counters)
      return
    end

    # Store the mapping for child processing
    @entity_mapping[path] = entity_id

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

  def initialize_progress!(import_data)
    return unless @progress_tracker

    @progress_tracker.set_total!(flattened_node_count(import_data))
  end

  def flattened_node_count(import_data)
    nodes = import_data["root_nodes"] || import_data[:root_nodes] || []
    nodes.sum { |node| 1 + flattened_children_count(node) }
  end

  def flattened_children_count(node)
    children = node["children"] || node[:children] || []
    children.sum { |child| 1 + flattened_children_count(child) }
  end

  def progress_counters
    {
      entities_created: @entities_created,
      entities_merged: @entities_merged,
      entities_skipped: @entities_skipped,
      observations_created: @observations_created,
      relations_created: @relations_created,
      relations_unresolved: @relations_unresolved,
      relations_skipped: @relations_skipped,
      errors: @errors.length
    }
  end

  # Handle skip action - entity already exists with same parent
  # Import any missing observations, then return the existing entity ID for child processing
  # @param node [Hash] Import node data
  # @return [Integer, nil] The existing entity ID
  def handle_skip_action(node)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]

    existing = find_entity_by_name_and_type(name, entity_type)

    if existing
      @logger.info "ImportExecutionStrategy: Skipping entity '#{name}' (already exists with same parent)"

      # Import any missing observations
      import_observations(node, existing.id)

      # Update counter cache if observations were added
      existing.update_column(:memory_observations_count, existing.memory_observations.count)

      @entities_skipped += 1
      existing.id
    else
      @logger.warn "ImportExecutionStrategy: Skip action but entity '#{name}' not found, creating instead"
      create_new_entity(node)
    end
  end

  # Handle exclude action - the node belongs to another project's subtree
  # (headless Graphify imports mark foreign subtrees this way). Unlike
  # `skip`, this is a true no-op: nothing is created, attached, or observed,
  # and the nil return stops the descent so the whole subtree is excluded.
  # @param node [Hash] Import node data
  # @return [nil]
  def handle_exclude_action(node)
    name = node[:name] || node["name"]
    @logger.info "ImportExecutionStrategy: Excluding '#{name}' (foreign subtree, left untouched)"
    @entities_skipped += 1
    record_excluded_subtree(node)
    nil
  end

  # Left untouched means untouched by the relations pass too: endpoints
  # resolve DB-wide, so without this an edge in the payload could still be
  # written between entities of the excluded project. Remember the matched
  # entity and its whole part_of subtree.
  def record_excluded_subtree(node)
    entity = ImportEntityResolver.find_by_name_and_type(
      node[:name] || node["name"], node[:entity_type] || node["entity_type"]
    )
    return unless entity

    @excluded_entity_ids.add(entity.id)
    @excluded_entity_ids.merge(RelationSemantics.descendant_ids(entity.id))
  end

  # Handle add_relation action - entity exists but needs relation to new parent
  # Add observations if they don't exist, relation will be created by caller
  # @param node [Hash] Import node data
  # @param parent_id [Integer, nil] The new parent entity ID
  # @return [Integer, nil] The existing entity ID
  def handle_add_relation_action(node, parent_id)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]

    existing = find_entity_by_name_and_type(name, entity_type)

    unless existing
      @logger.warn "ImportExecutionStrategy: Add relation action but entity '#{name}' not found, creating instead"
      return create_new_entity(node)
    end

    @logger.info "ImportExecutionStrategy: Adding relation for entity '#{name}' (#{existing.id}) to parent #{parent_id}"

    # Add observations if not duplicates
    import_observations(node, existing.id)

    # Update counter cache
    existing.update_column(:memory_observations_count, existing.memory_observations.count)

    @entities_merged += 1
    existing.id
  end

  # Merge import data into an existing entity
  # @param node [Hash] Import node data
  # @param target_id [Integer] ID of existing entity to merge into
  # @return [Integer, nil] The target entity ID on success
  def merge_into_existing(node, target_id)
    target_entity = MemoryEntity.find_by(id: target_id)
    unless target_entity
      @errors << "Target entity #{target_id} not found for merge"
      return nil
    end

    @logger.info "ImportExecutionStrategy: Merging into entity #{target_id} (#{target_entity.name})"

    # Merge aliases
    import_aliases = (node[:aliases] || node["aliases"]).to_s
    if import_aliases.present?
      existing_aliases = target_entity.aliases.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
      new_aliases = import_aliases.split(/[,|;]/).map(&:strip).reject(&:blank?)
      merged_aliases = (existing_aliases + new_aliases).uniq.join(",")
      target_entity.update!(aliases: merged_aliases)
    end

    # Add observations
    import_observations(node, target_entity.id)

    # Update counter cache
    target_entity.update_column(:memory_observations_count, target_entity.memory_observations.count)

    @entities_merged += 1
    target_entity.id
  rescue ActiveRecord::RecordInvalid => e
    @errors << "Failed to merge into entity #{target_id}: #{e.message}"
    nil
  end

  # Create a new entity from import data
  # @param node [Hash] Import node data
  # @return [Integer, nil] The new entity ID on success
  def create_new_entity(node)
    name = node[:name] || node["name"]
    entity_type = node[:entity_type] || node["entity_type"]
    aliases = node[:aliases] || node["aliases"]

    @logger.info "ImportExecutionStrategy: Creating new entity '#{name}' (#{entity_type})"

    # Check if entity with same name and type already exists
    existing = find_entity_by_name_and_type(name, entity_type)
    if existing
      @logger.warn "ImportExecutionStrategy: Entity '#{name}' already exists, merging instead"
      return merge_into_existing(node, existing.id)
    end

    entity = MemoryEntity.create!(
      name: name,
      entity_type: entity_type,
      aliases: aliases
    )

    # Add observations
    import_observations(node, entity.id)

    # Update counter cache
    entity.update_column(:memory_observations_count, entity.memory_observations.count)

    @entities_created += 1
    entity.id
  rescue ActiveRecord::RecordInvalid => e
    @errors << "Failed to create entity '#{name}': #{e.message}"
    nil
  end

  # Import observations for an entity
  # @param node [Hash] Import node data
  # @param entity_id [Integer] Target entity ID
  def import_observations(node, entity_id)
    observations = node[:observations] || node["observations"] || []
    entity = MemoryEntity.find(entity_id)
    contents_seen = Set.new
    observations_to_create = observations.filter do |obs_data|
      content = obs_data[:content] || obs_data["content"]
      next false if content.blank? || contents_seen.include?(content)

      contents_seen.add(content)
      !@observation_duplicate_detector.find_duplicate(entity: entity, content: content).duplicate
    end

    observations_to_create.each do |obs_data|
      content = obs_data[:content] || obs_data["content"]

      MemoryObservation.create!(
        memory_entity_id: entity_id,
        content: content,
        confidence: obs_data[:confidence] || obs_data["confidence"],
        source: obs_data[:source] || obs_data["source"],
        valid_from: obs_data[:valid_from] || obs_data["valid_from"],
        valid_until: obs_data[:valid_until] || obs_data["valid_until"],
        tags: obs_data[:tags] || obs_data["tags"] || []
      )
      @observations_created += 1
    rescue ActiveRecord::RecordInvalid => e
      @errors << "Failed to create observation for entity #{entity_id}: #{e.message}"
    end
  end

  # Apply name+type-addressed relations after the entity tree exists.
  # Edges whose endpoints cannot be resolved are skipped and counted — never
  # fatal — so a partially-resolvable graph still imports cleanly.
  #
  # Design decisions (PR #96 review):
  # - Endpoints resolve against the WHOLE database, not just this import's
  #   accepted tree nodes. Name+type-addressed edges are meant to cross
  #   import boundaries: a file imported today must link onto entities
  #   imported in earlier runs, so "not in this payload" is not "missing".
  #   Only genuinely absent endpoints count as unresolved.
  # - A skipped tree node still receives its imported edges: `skip` means
  #   "entity already exists with this parent" — the entity stays part of
  #   the processed tree, so upserting its relations is the intended
  #   rescan behaviour, not an operator exclusion.
  # @param relations [Array<Hash>, nil] {from_name, from_type, to_name, to_type,
  #   relation_type, weight, confidence, properties}
  def apply_relations(relations)
    return if relations.blank?

    # One (name, canonical_type) -> id map for every endpoint and one
    # preloaded set of existing triples: a 50k-edge payload cannot afford
    # two find_by + canonicalize + exists? lookups per edge.
    endpoint_ids = resolve_relation_endpoints(relations)
    existing = preload_existing_relations(relations, endpoint_ids)

    Array(relations).each do |relation|
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
      to_id = endpoint_ids[endpoint_key(relation["to_name"] || relation[:to_name],
                                        relation["to_type"] || relation[:to_type])]

      unless from_id && to_id
        @relations_unresolved += 1
        next
      end

      # Excluded foreign subtrees are left untouched — including their
      # edges: an endpoint inside one means this edge belongs to the other
      # project's graph, not this import's.
      if @excluded_entity_ids.include?(from_id) || @excluded_entity_ids.include?(to_id)
        @relations_skipped += 1
        next
      end

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
  # payload to a MemoryEntity id with a single query.
  def resolve_relation_endpoints(relations)
    names = []
    types = []
    Array(relations).each do |relation|
      names << (relation["from_name"] || relation[:from_name])
      names << (relation["to_name"] || relation[:to_name])
      types << (relation["from_type"] || relation[:from_type])
      types << (relation["to_type"] || relation[:to_type])
    end
    canonical_types = types.uniq.map { |type| ImportEntityResolver.canonical_type(type) }.uniq

    MemoryEntity.where(name: names.uniq, entity_type: canonical_types)
                .pluck(:name, :entity_type, :id)
                .each_with_object({}) do |(name, entity_type, id), map|
      map[[ name.to_s.downcase, entity_type.to_s.downcase ]] ||= id
    end
  end

  # Downcased name AND type: memory_entities.name uses a case-insensitive
  # collation, and the old per-edge find_by_name_and_type matched
  # "FooService"/"Service" for "fooservice"/"service" — the bulk map must
  # keep that behavior for types missing from the mapping table too.
  def endpoint_key(name, raw_type)
    [ name.to_s.downcase, ImportEntityResolver.canonical_type(raw_type).to_s.downcase ]
  end

  # All (from_id, to_id, canonical_type) triples the resolvable relations
  # already have in the DB — one query instead of an exists? per edge. The
  # set doubles as the intra-payload dedupe: create_relation_safe adds each
  # created triple to it.
  def preload_existing_relations(relations, endpoint_ids)
    triples = Array(relations).filter_map do |relation|
      raw_type = relation["relation_type"] || relation[:relation_type]
      next if RelationSemantics.hierarchical?(raw_type)

      from_id = endpoint_ids[endpoint_key(relation["from_name"] || relation[:from_name],
                                          relation["from_type"] || relation[:from_type])]
      to_id = endpoint_ids[endpoint_key(relation["to_name"] || relation[:to_name],
                                        relation["to_type"] || relation[:to_type])]
      [ from_id, to_id, MemoryRelation.canonical_relation_type(raw_type) ] if from_id && to_id
    end
    return Set.new if triples.empty?

    MemoryRelation
      .where(from_entity_id: triples.map(&:first).uniq,
             to_entity_id: triples.map(&:second).uniq,
             relation_type: triples.map(&:third).uniq)
      .pluck(:from_entity_id, :to_entity_id, :relation_type)
      .each_with_object(Set.new) { |(from_id, to_id, type), set| set << [ from_id, to_id, type ] }
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
  rescue RelationSemantics::ValidationError, ActiveRecord::RecordInvalid => e
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

  def find_entity_by_name_and_type(name, entity_type)
    ImportEntityResolver.find_by_name_and_type(name, entity_type)
  end

  def relation_endpoints(entity_id, parent_id, direction)
    return [ parent_id, entity_id ] if direction == "parent_to_child"

    [ entity_id, parent_id ]
  end

  def failed_report
    ImportReport.new(
      success: false,
      entities_created: 0,
      entities_merged: 0,
      entities_skipped: 0,
      observations_created: 0,
      observations_obsoleted: 0,
      observations_superseded: 0,
      relations_created: 0,
      relations_unresolved: 0,
      relations_skipped: 0,
      # A rolled-back import never committed rescan mutations (the phase-1
      # diff runs inside the same transaction) and never seeded review
      # items — the failure report must not claim them.
      rescan: false,
      rescan_entities_flagged: 0,
      rescan_relations_flagged: 0,
      rescan_reparents_flagged: 0,
      errors: @errors
    )
  end

  # Resolves the entity the import's root node would merge into. The rescan
  # diff only runs when the root already exists AND has graphify-sourced
  # descendants — i.e. this is genuinely a second scan of the same project.
  # When the operator picked a merge target, THAT entity is the root to
  # diff — its subtree is the one being re-scanned, not the payload
  # namesake's (which could be a different project entirely).
  def rescan_root_entity(import_data, decision_map)
    root_decision = decision_map["0"] || {}
    if %w[merge add_relation].include?(root_decision[:action] || root_decision["action"]) &&
       (root_decision[:target_id] || root_decision["target_id"]).present?
      target = MemoryEntity.find_by(id: root_decision[:target_id] || root_decision["target_id"])
      return target if target
    end

    root_payload = Array(import_data["root_nodes"] || import_data[:root_nodes]).first
    return nil unless root_payload.is_a?(Hash)

    find_entity_by_name_and_type(root_payload["name"] || root_payload[:name],
                                 root_payload["entity_type"] || root_payload[:entity_type])
  end

  def rescan_source_ref(import_data)
    root_payload = Array(import_data["root_nodes"] || import_data[:root_nodes]).first || {}
    root_payload["name"] || root_payload[:name]
  end

  def resolve_parent_id(decision, path)
    explicit_parent = decision&.dig(:parent_id) || decision&.dig("parent_id")
    return explicit_parent if explicit_parent.present?

    parent_path = decision&.dig(:parent_path) || decision&.dig("parent_path")
    return @entity_mapping[parent_path] if parent_path.present?

    nil
  end
end
