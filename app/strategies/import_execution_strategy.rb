# frozen_string_literal: true

# Strategy class for executing the data import based on operator decisions
#
# This strategy:
# - Processes match results with operator selections
# - Creates new entities or merges into existing ones
# - Transfers observations and creates relations
# - Wraps everything in a transaction for atomicity
# - Returns detailed report of the import operation
class ImportExecutionStrategy
  # Result struct for import report
  ImportReport = Struct.new(
    :success,
    :entities_created,
    :entities_merged,
    :observations_created,
    :relations_created,
    :errors,
    keyword_init: true
  ) do
    def to_h
      {
        success: success,
        entities_created: entities_created,
        entities_merged: entities_merged,
        observations_created: observations_created,
        relations_created: relations_created,
        errors: errors
      }
    end
  end

  def initialize
    @logger = Rails.logger
    @entities_created = 0
    @entities_merged = 0
    @observations_created = 0
    @relations_created = 0
    @errors = []
    @entity_mapping = {} # Maps import node paths to created/matched entity IDs
  end

  # Execute the import based on operator decisions
  # @param import_data [Hash] Original parsed import JSON
  # @param decisions [Array<Hash>] Operator decisions for each node
  #   Each decision has: { node_path:, action: ("create" | "merge"), target_id:, parent_id: }
  # @return [ImportReport] Report of the import operation
  def execute(import_data, decisions)
    @logger.info "ImportExecutionStrategy: Starting import execution"

    # Build decision lookup by node path
    decision_map = decisions.index_by { |d| d[:node_path] || d["node_path"] }

    ActiveRecord::Base.transaction do
      root_nodes = import_data["root_nodes"] || import_data[:root_nodes] || []

      root_nodes.each_with_index do |root_node, index|
        path = index.to_s
        decision = decision_map[path]
        parent_id = decision&.dig(:parent_id) || decision&.dig("parent_id")

        process_node_recursive(root_node, path, decision_map, parent_id, nil)
      end
    end

    ImportReport.new(
      success: @errors.empty?,
      entities_created: @entities_created,
      entities_merged: @entities_merged,
      observations_created: @observations_created,
      relations_created: @relations_created,
      errors: @errors
    )
  rescue ActiveRecord::RecordInvalid => e
    @logger.error "ImportExecutionStrategy: Transaction failed: #{e.message}"
    @errors << "Transaction failed: #{e.message}"

    ImportReport.new(
      success: false,
      entities_created: 0,
      entities_merged: 0,
      observations_created: 0,
      relations_created: 0,
      errors: @errors
    )
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

    # Determine the action and target
    action = decision&.dig(:action) || decision&.dig("action") || "create"
    target_id = decision&.dig(:target_id) || decision&.dig("target_id")

    # Process this node
    entity_id = if action == "merge" && target_id.present?
      merge_into_existing(node, target_id)
    else
      create_new_entity(node)
    end

    return unless entity_id

    # Store the mapping for child processing
    @entity_mapping[path] = entity_id

    # Create relation to parent (either explicit parent_entity_id or tree parent)
    actual_parent_id = parent_entity_id || tree_parent_id
    if actual_parent_id.present? && actual_parent_id != entity_id
      relation_type = node[:relation_type] || node["relation_type"] || "part_of"
      create_relation_safe(entity_id, actual_parent_id, relation_type)
    end

    # Process children
    children = node["children"] || node[:children] || []
    children.each_with_index do |child, index|
      child_path = "#{path}.children.#{index}"
      # Children inherit this entity as their tree parent
      process_node_recursive(child, child_path, decision_map, nil, entity_id)
    end
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

    # Check if entity with same name already exists
    existing = MemoryEntity.find_by(name: name)
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

    observations.each do |obs_data|
      content = obs_data[:content] || obs_data["content"]
      next if content.blank?

      # Skip duplicates
      existing = MemoryObservation.exists?(memory_entity_id: entity_id, content: content)
      next if existing

      MemoryObservation.create!(
        memory_entity_id: entity_id,
        content: content
      )
      @observations_created += 1
    rescue ActiveRecord::RecordInvalid => e
      @errors << "Failed to create observation for entity #{entity_id}: #{e.message}"
    end
  end

  # Create a relation safely (handling duplicates)
  # @param from_entity_id [Integer] Child/source entity ID
  # @param to_entity_id [Integer] Parent/target entity ID
  # @param relation_type [String] Type of relation
  def create_relation_safe(from_entity_id, to_entity_id, relation_type)
    return if from_entity_id == to_entity_id # No self-loops

    # Check for existing relation
    existing = MemoryRelation.exists?(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: relation_type
    )
    return if existing

    MemoryRelation.create!(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: relation_type
    )
    @relations_created += 1
    @logger.debug "ImportExecutionStrategy: Created relation #{from_entity_id} -[#{relation_type}]-> #{to_entity_id}"
  rescue ActiveRecord::RecordInvalid => e
    @errors << "Failed to create relation (#{from_entity_id} -> #{to_entity_id}): #{e.message}"
  end
end
