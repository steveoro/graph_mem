# frozen_string_literal: true

# Progress, report and rescan bookkeeping for ImportExecutionStrategy
# (extracted for the 500-line rule).
module ImportExecutionStrategy::Reporting
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

  def failed_report
    ImportExecutionStrategy::ImportReport.new(
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

  # The producer whose stored facts this rescan reconciles. "rescan" => true
  # means the graphify bucket (A3 default); a producer may pass its own name
  # (e.g. "rails_ast_extractor") so a re-scan diffs only the facts that
  # producer owns and never flags another producer's observations/edges.
  def rescan_source(import_data)
    marker = import_data["rescan"] || import_data[:rescan]
    marker.is_a?(String) ? marker : GraphifyImporter::SOURCE_NAME
  end
end
