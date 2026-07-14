# frozen_string_literal: true

# Strategy class for node operations (move, merge, delete)
#
# This strategy provides clean-up operations for orphan nodes:
# - Move: Attach an orphan node (and its subtree) to a new parent
# - Merge: Merge a source node into a target node (combining data)
# - Delete: Remove a node (with options for handling children)
class NodeOperationsStrategy
  class ProjectRootProtected < StandardError; end

  # Relation types that define parent-child relationships
  CHILD_RELATION_TYPES = %w[part_of depends_on].freeze
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

    # Check if relation already exists
    existing_relation = MemoryRelation.find_by(
      from_entity_id: node_id,
      to_entity_id: parent_id,
      relation_type: "part_of"
    )

    if existing_relation
      return error_result("Node is already a child of this parent")
    end

    ActiveRecord::Base.transaction do
      # Remove any existing parent relations (to make it a child of the new parent only)
      MemoryRelation
        .where(from_entity_id: node_id, relation_type: CHILD_RELATION_TYPES)
        .destroy_all

      # Create new relation
      MemoryRelation.create!(
        from_entity_id: node_id,
        to_entity_id: parent_id,
        relation_type: "part_of"
      )

      @logger.info "NodeOperationsStrategy: Moved node #{node.name} (#{node_id}) to parent #{parent.name} (#{parent_id})"
    end

    success_result("Successfully moved '#{node.name}' under '#{parent.name}'")
  rescue ActiveRecord::RecordInvalid => e
    error_result("Failed to move node: #{e.message}")
  end

  # Merge a source node into a target node
  # - Adds source name to target aliases
  # - Transfers all observations to target
  # - Re-parents all children to target
  # - Deletes the source node
  # @param source_id [Integer] The source node to merge from
  # @param target_id [Integer] The target node to merge into
  # @return [Hash] Result with :success and :message or :error
  def merge_into(source_id, target_id)
    attempts = 0

    begin
      merge_into_once(source_id, target_id)
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

  def merge_into_once(source_id, target_id)
    return error_result("Cannot merge a node into itself") if source_id == target_id

    source_name = nil
    target_name = nil
    transferred_observations = 0
    result = nil

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
      if project_root?(source)
        result = error_result(PROJECT_ROOT_PROTECTED_ERROR)
        next
      end

      # Add source name and aliases to target aliases
      merge_aliases(source, target)

      # Transfer observations from source to target
      transferred_observations = source.memory_observations.count
      source.memory_observations.update_all(memory_entity_id: target_id)

      reassign_outgoing_relations!(source_id, target_id)
      reassign_incoming_relations!(source_id, target_id)

      # Delete any relations that were directly between source and target
      MemoryRelation.where(from_entity_id: source_id, to_entity_id: target_id).destroy_all
      MemoryRelation.where(from_entity_id: target_id, to_entity_id: source_id).destroy_all

      # Clean up duplicate relations that may have been created
      cleanup_duplicate_relations(target_id)

      # Update counter cache
      target.update_column(:memory_observations_count, target.memory_observations.count)

      # Delete the source entity
      source_name = source.name
      target_name = target.name
      source.destroy!

      @logger.info "NodeOperationsStrategy: Merged '#{source_name}' (#{source_id}) into '#{target_name}' (#{target_id}). Transferred #{transferred_observations} observations."
    end

    return result if result

    success_result("Successfully merged '#{source_name}' into '#{target_name}'")
  end

  # Delete a node
  # Children will become orphans unless cascade_delete is true
  # @param node_id [Integer] The node to delete
  # @param cascade_delete [Boolean] If true, delete all descendants too
  # @return [Hash] Result with :success and :message or :error
  def delete_node(node_id, cascade_delete: false)
    node = MemoryEntity.find_by(id: node_id)

    return error_result("Node not found") unless node
    return error_result(PROJECT_ROOT_PROTECTED_ERROR) if project_root?(node)

    node_name = node.name
    deleted_count = 0

    ActiveRecord::Base.transaction do
      if cascade_delete
        # Delete all descendants first
        deleted_count = delete_descendants(node_id)
      else
        # Just remove relations pointing to this node (children become orphans)
        MemoryRelation
          .where(to_entity_id: node_id, relation_type: CHILD_RELATION_TYPES)
          .destroy_all
      end

      # Delete the node itself (observations will be deleted via dependent: :destroy)
      node.destroy!
      deleted_count += 1

      @logger.info "NodeOperationsStrategy: Deleted node '#{node_name}' (#{node_id}). Total deleted: #{deleted_count}"
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
  def reassign_incoming_relations!(source_id, target_id)
    MemoryRelation.where(to_entity_id: source_id).where.not(from_entity_id: target_id).find_each do |relation|
      if MemoryRelation.exists?(
        from_entity_id: relation.from_entity_id,
        to_entity_id: target_id,
        relation_type: relation.relation_type
      )
        relation.destroy!
      else
        relation.update!(to_entity_id: target_id)
      end
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
      .where(to_entity_id: node_id, relation_type: CHILD_RELATION_TYPES)
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
