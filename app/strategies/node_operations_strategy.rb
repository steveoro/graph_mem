# frozen_string_literal: true

# Strategy class for node operations (move, merge, delete)
#
# This strategy provides clean-up operations for orphan nodes:
# - Move: Attach an orphan node (and its subtree) to a new parent
# - Merge: Merge a source node into a target node (combining data)
# - Delete: Remove a node (with options for handling children)
class NodeOperationsStrategy
  class ProjectRootProtected < StandardError; end

  # Relation types that define parent-child hierarchy (part_of only)
  CHILD_RELATION_TYPES = RelationSemantics::CHILD_RELATION_TYPES
  PROJECT_ENTITY_TYPE = "Project"
  PROJECT_ROOT_PROTECTED_ERROR = "Project root entities cannot be deleted or merged away"
  MAX_MERGE_RETRIES = 3
  MERGE_RETRY_BASE_DELAY = 0.05
  TRANSIENT_MERGE_ERRORS = [
    /record has changed since last read/i,
    /deadlock found/i,
    /lock wait timeout/i
  ].freeze

  def initialize
    @logger = Rails.logger
  end

  # Move a node to become a child of a new parent
  # Creates a "part_of" relation from the node to the parent
  # @param node_id [Integer] The node to move
  # @param parent_id [Integer] The new parent
  # @return [Hash] Result with :success and :message or :error
  def move_to_parent(node_id, parent_id)
    node = MemoryEntity.find_by(id: node_id)
    parent = MemoryEntity.find_by(id: parent_id)

    return error_result("Node not found") unless node
    return error_result("Parent node not found") unless parent
    return error_result("Cannot move a node to itself") if node_id == parent_id
    if RelationSemantics.would_create_cycle?(node_id, parent_id)
      return error_result("Cannot move node: would create a part_of cycle")
    end

    # Check if relation already exists
    existing_relation = MemoryRelation.find_by(
      from_entity_id: node_id,
      to_entity_id: parent_id,
      relation_type: "part_of"
    )

    if existing_relation
      return error_result("Node is already a child of this parent")
    end

    # Membership lock BEFORE the transaction: taking GET_LOCK while
    # holding row locks deadlocks against the backfill (advisory-first).
    ProjectMembership.with_membership_lock do
      ActiveRecord::Base.transaction do
        # Remove only existing hierarchy parents; preserve depends_on edges
        MemoryRelation
          .where(from_entity_id: node_id, relation_type: "part_of")
          .destroy_all

        # Create new relation
        MemoryRelation.create!(
          from_entity_id: node_id,
          to_entity_id: parent_id,
          relation_type: "part_of"
        )

        # Moving under a new parent moves the node (and its subtree) into the
        # new parent's project scope; ProjectMembership refuses the move on a
        # same-name collision in the target project.
        ProjectMembership.sync!(node)

        @logger.info "NodeOperationsStrategy: Moved node #{node.name} (#{node_id}) to parent #{parent.name} (#{parent_id})"
      end
    end

    success_result("Successfully moved '#{node.name}' under '#{parent.name}'")
  rescue ActiveRecord::RecordInvalid, ProjectMembership::Collision => e
    error_result("Failed to move node: #{e.message}")
  end

  # Merge a source node into a target node
  # - Adds source name to target aliases
  # - Transfers all observations to target
  # - Re-parents all children to target
  # - Deletes the source node
  # @param source_id [Integer] The source node to merge from
  # @param target_id [Integer] The target node to merge into
  # @param change_set_kind [String] the ChangeSet kind when no set is open (a set already open,
  #   e.g. a graph_delete batch or a review apply, records the merge instead)
  # @return [Hash] Result with :success and :message (plus :change_set_uuid) or :error
  def merge_into(source_id, target_id, change_set_kind: "merge")
    attempts = 0

    begin
      merge_into_once(source_id, target_id, change_set_kind: change_set_kind)
    rescue ActiveRecord::RecordNotUnique => e
      error_result("Failed to merge nodes: duplicate relation would be created (#{e.message})")
    rescue ActiveRecord::StatementInvalid => e
      raise unless transient_merge_error?(e) && attempts < MAX_MERGE_RETRIES

      attempts += 1
      delay = MERGE_RETRY_BASE_DELAY * (2**(attempts - 1))
      @logger.warn "NodeOperationsStrategy: retrying merge #{source_id}->#{target_id} (#{attempts}/#{MAX_MERGE_RETRIES}) after #{e.class}: #{e.message}"
      sleep(delay)
      retry
    rescue ActiveRecord::RecordInvalid => e
      error_result("Failed to merge nodes: #{e.message}")
    end
  end

  def merge_into_once(source_id, target_id, change_set_kind: "merge")
    return error_result("Cannot merge a node into itself") if source_id == target_id

    source_name = nil
    target_name = nil
    transferred_observations = 0
    result = nil
    change_set_uuid = nil

    begin
      Current.deletion_reason = "duplicate"
      # Membership lock BEFORE the transaction — see move_node.
      ProjectMembership.with_membership_lock do
        ActiveRecord::Base.transaction do
          locked_entities = MemoryEntity
          .where(id: [ source_id, target_id ])
          .order(:id)
          .lock
          .to_a
          .index_by(&:id)
        source = locked_entities[source_id]
        target = locked_entities[target_id]

        unless source
          result = error_result("Source node not found")
          next
        end
        unless target
          result = error_result("Target node not found")
          next
        end
        if project_root?(source) || project_root?(target)
          result = error_result(PROJECT_ROOT_PROTECTED_ERROR)
          next
        end

        if source.entity_type != target.entity_type
          result = error_result(
            "Cannot merge entities of different types: " \
            "'#{source.entity_type}' into '#{target.entity_type}'"
          )
          next
        end

        # Explicit merges keep the caller-provided source→target direction.
        # Dream-state may call pick_survivor before invoking merge_into.
        source_name = source.name
        target_name = target.name
        summary = "merged '#{source_name}' into '#{target_name}'"
        ChangeSet.record(kind: change_set_kind, subject: target, summary: summary) do |change_set|
          change_set_uuid = change_set.uuid
          # The undo snapshot (UI-4a): a failed snapshot write raises and rolls the merge back.
          before = EntityMergeSnapshot.capture_before(source, target)
          transferred_observations = before["observation_ids"].size
          change_set.within_merge_step { merge_locked!(source, target) }
          change_set.add_merge_step!(EntityMergeSnapshot.complete(before, target))
        end

        @logger.info "NodeOperationsStrategy: Merged '#{source_name}' (#{source_id}) into '#{target_name}' (#{target_id}). Transferred #{transferred_observations} observations."
        end
      end
    ensure
      Current.deletion_reason = nil
    end

    return result if result

    success_result("Successfully merged '#{source_name}' into '#{target_name}'").merge(change_set_uuid: change_set_uuid)
  end

  # Delete a node
  # Children will become orphans unless cascade_delete is true
  # @param node_id [Integer] The node to delete
  # @param cascade_delete [Boolean] If true, delete all descendants too
  # @param reason [String, nil] Optional reason for the deletion
  # @return [Hash] Result with :success and :message or :error
  def delete_node(node_id, cascade_delete: false, reason: nil)
    node = MemoryEntity.find_by(id: node_id)

    return error_result("Node not found") unless node
    return error_result(PROJECT_ROOT_PROTECTED_ERROR) if project_root?(node)

    node_name = node.name
    deleted_count = 0

    begin
      Current.deletion_reason = reason
      # Membership lock BEFORE the transaction — see move_node.
      ProjectMembership.with_membership_lock do
        ActiveRecord::Base.transaction do
          if cascade_delete
            # Delete all descendants first
            deleted_count = delete_descendants(node_id)
          else
            # Remove hierarchy links only; descendants with another parent remain attached.
            # Orphaned children lose their part_of chain → unrooted (global);
            # re-sync them so project_id mirrors the CURRENT edges.
            orphan_ids = MemoryRelation.where(to_entity_id: node_id, relation_type: "part_of")
                                       .pluck(:from_entity_id)
            MemoryRelation
              .where(to_entity_id: node_id, relation_type: "part_of")
              .destroy_all
            orphan_ids.each do |child_id|
              orphan = MemoryEntity.find_by(id: child_id)
              ProjectMembership.sync!(orphan) if orphan
            end
          end

          # Delete the node itself (observations will be deleted via dependent: :destroy)
          node.destroy!
          deleted_count += 1

          @logger.info "NodeOperationsStrategy: Deleted node '#{node_name}' (#{node_id}). Total deleted: #{deleted_count}"
        end
      end
    ensure
      Current.deletion_reason = nil
    end

    message = cascade_delete ?
      "Successfully deleted '#{node_name}' and #{deleted_count - 1} descendants" :
      "Successfully deleted '#{node_name}'"

    success_result(message)
  rescue ActiveRecord::RecordInvalid => e
    error_result("Failed to delete node: #{e.message}")
  rescue ProjectRootProtected
    error_result(PROJECT_ROOT_PROTECTED_ERROR)
  end

  private

  def project_root?(entity)
    entity.entity_type == PROJECT_ENTITY_TYPE
  end

  def success_result(message)
    { success: true, message: message }
  end

  def error_result(error)
    { success: false, error: error }
  end

  # The merge itself, on rows locked by merge_into_once.
  def merge_locked!(source, target)
    # Add source name and aliases to target aliases
    merge_aliases(source, target)
    # Transfer observations from source to target and recompute trust
    transfer_observations!(source, target)

    reassign_outgoing_relations!(source.id, target.id)
    reassign_incoming_relations!(source.id, target.id)

    # Delete any relations that were directly between source and target
    MemoryRelation.where(from_entity_id: source.id, to_entity_id: target.id).destroy_all
    MemoryRelation.where(from_entity_id: target.id, to_entity_id: source.id).destroy_all

    # Clean up duplicate relations that may have been created
    cleanup_duplicate_relations(target.id)

    # Update counter cache
    target.update_column(:memory_observations_count, target.memory_observations.count)

    # Delete the source entity
    source.destroy!
  end

  def transient_merge_error?(error)
    message = error.message.to_s
    TRANSIENT_MERGE_ERRORS.any? { |pattern| message.match?(pattern) }
  end

  # Merge aliases from source to target
  def merge_aliases(source, target)
    existing_aliases = parse_aliases(target.aliases)
    source_aliases = parse_aliases(source.aliases)

    # Add source name as an alias if it's different from target name
    source_aliases << source.name unless source.name.downcase == target.name.downcase

    # Combine and deduplicate
    all_aliases = (existing_aliases + source_aliases).map(&:strip).reject(&:blank?).uniq

    target.update!(aliases: all_aliases.join(","))
  end

  def transfer_observations!(source, target)
    source.memory_observations.find_each do |observation|
      observation.assign_attributes(memory_entity_id: target.id)
      observation.trust_score = ObservationTrustRanker.rank(observation)
      observation.save!
      # No re-embedding: an observation's vector depends only on its content, source and tags
      # (EmbeddingService#compose_observation_text), not on the owning entity. Calling the
      # embedding service here would hold the membership lock and the row locks across HTTP calls.
    end
  end

  # Parse comma-separated aliases into array
  def parse_aliases(aliases_string)
    return [] if aliases_string.blank?

    aliases_string.split(/[,|;]/).map(&:strip).reject(&:blank?)
  end

  # Re-assign outgoing relations (source -> X) without violating uniqueness.
  def reassign_outgoing_relations!(source_id, target_id)
    MemoryRelation.where(from_entity_id: source_id).where.not(to_entity_id: target_id).find_each do |relation|
      if MemoryRelation.exists?(
        from_entity_id: target_id,
        to_entity_id: relation.to_entity_id,
        relation_type: relation.relation_type
      )
        relation.destroy!
      else
        relation.update!(from_entity_id: target_id)
      end
    end
  end

  # Re-assign incoming relations (X -> source) without violating uniqueness.
  # part_of children re-pointed under the target change scope when the
  # target lives in a different project — re-sync their membership or
  # they keep the SOURCE project's stamp inside the target's tree.
  def reassign_incoming_relations!(source_id, target_id)
    reparented_child_ids = []
    MemoryRelation.where(to_entity_id: source_id).where.not(from_entity_id: target_id).find_each do |relation|
      if MemoryRelation.exists?(
        from_entity_id: relation.from_entity_id,
        to_entity_id: target_id,
        relation_type: relation.relation_type
      )
        reparented_child_ids << relation.from_entity_id if relation.relation_type == "part_of"
        relation.destroy!
      else
        reparented_child_ids << relation.from_entity_id if relation.relation_type == "part_of"
        relation.update!(to_entity_id: target_id)
      end
    end
    reparented_child_ids.uniq.each do |child_id|
      entity = MemoryEntity.find_by(id: child_id)
      ProjectMembership.sync!(entity) if entity
    end
  end

  # Clean up duplicate relations for a target entity
  # Keeps only one relation of each (from_id, to_id, type) combination
  def cleanup_duplicate_relations(entity_id)
    # Find duplicate relations where entity is 'from'
    MemoryRelation
      .where(from_entity_id: entity_id)
      .group(:from_entity_id, :to_entity_id, :relation_type)
      .having("COUNT(*) > 1")
      .count
      .keys
      .each do |(from_id, to_id, rel_type)|
        relations = MemoryRelation.where(
          from_entity_id: from_id,
          to_entity_id: to_id,
          relation_type: rel_type
        ).order(:id)

        # Keep the first, delete the rest
        relations.offset(1).destroy_all
      end

    # Find duplicate relations where entity is 'to'
    MemoryRelation
      .where(to_entity_id: entity_id)
      .group(:from_entity_id, :to_entity_id, :relation_type)
      .having("COUNT(*) > 1")
      .count
      .keys
      .each do |(from_id, to_id, rel_type)|
        relations = MemoryRelation.where(
          from_entity_id: from_id,
          to_entity_id: to_id,
          relation_type: rel_type
        ).order(:id)

        # Keep the first, delete the rest
        relations.offset(1).destroy_all
      end
  end

  # Recursively delete all descendants of a node
  # @return [Integer] Number of descendants deleted
  def delete_descendants(node_id)
    count = 0

    # Find direct children
    child_ids = MemoryRelation
      .where(to_entity_id: node_id, relation_type: "part_of")
      .pluck(:from_entity_id)

    child_ids.each do |child_id|
      child = MemoryEntity.find_by(id: child_id)
      next unless child

      raise ProjectRootProtected if project_root?(child)

      count += delete_descendants(child_id)
      child.destroy!
      count += 1
    end

    count
  end
end
