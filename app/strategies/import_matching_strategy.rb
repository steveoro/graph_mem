# frozen_string_literal: true

# Strategy class for matching imported data against existing graph entities
#
# This strategy:
# - Parses JSON import data
# - For root/Project nodes, uses EntitySearchStrategy to find potential matches
# - For child nodes, uses 1:1 exact matching by name+type
# - Calculates confidence scores and status
# - Returns structured match results for operator review
class ImportMatchingStrategy
  # Confidence thresholds (for root nodes)
  HIGH_CONFIDENCE_THRESHOLD = 20
  LOW_CONFIDENCE_THRESHOLD = 10

  # Status indicators
  STATUS_HIGH_CONFIDENCE = "high"    # Green - exact or near-exact match
  STATUS_LOW_CONFIDENCE = "low"      # Yellow - possible match, needs review
  STATUS_NEW = "new"                 # Grey - no match found, will be created
  STATUS_SKIP = "skip"               # Blue - child already exists with same parent
  STATUS_ADD_RELATION = "add_relation"  # Purple - child exists but needs relation to new parent

  # Child action types
  CHILD_ACTION_SKIP = "skip"
  CHILD_ACTION_ADD_RELATION = "add_relation"
  CHILD_ACTION_CREATE = "create"

  # Relation types that define parent-child relationships
  CHILD_RELATION_TYPES = %w[part_of depends_on].freeze

  # Result struct for individual node matching
  MatchResult = Struct.new(
    :import_node,          # Hash: the imported node data
    :matches,              # Array: potential existing matches with scores (for root nodes)
    :status,               # String: high/low/new/skip/add_relation
    :selected_match_id,    # Integer: ID of selected match (nil for new)
    :parent_entity_id,     # Integer: ID of parent entity to attach to (for root imports)
    :node_path,            # String: path in import tree (e.g., "0.children.2")
    :is_child,             # Boolean: true if this is a child node
    :import_parent_name,   # String: name of parent in import data
    :exact_match,          # MemoryEntity: for children - single 1:1 match entity
    :child_action,         # String: "skip", "add_relation", "create"
    :will_add_observations, # Boolean: whether observations will be added
    keyword_init: true
  ) do
    def to_h
      base = {
        import_node: {
          name: import_node[:name],
          entity_type: import_node[:entity_type],
          aliases: import_node[:aliases],
          observations_count: import_node[:observations]&.length || 0,
          children_count: import_node[:children]&.length || 0,
          relation_type: import_node[:relation_type]
        },
        status: status,
        node_path: node_path,
        is_child: is_child || false,
        import_parent_name: import_parent_name
      }

      if is_child
        base[:child_action] = child_action
        base[:will_add_observations] = will_add_observations || false
        base[:exact_match] = exact_match ? {
          entity_id: exact_match.id,
          name: exact_match.name,
          entity_type: exact_match.entity_type
        } : nil
        base[:matches] = []
      else
        base[:matches] = (matches || []).map do |m|
          {
            entity_id: m[:entity].id,
            name: m[:entity].name,
            entity_type: m[:entity].entity_type,
            aliases: m[:entity].aliases,
            score: m[:score],
            matched_fields: m[:matched_fields]
          }
        end
        base[:selected_match_id] = selected_match_id
        base[:parent_entity_id] = parent_entity_id
      end

      base
    end
  end

  def initialize
    @logger = Rails.logger
    @search_strategy = EntitySearchStrategy.new
  end

  # Parse and match import data
  # @param json_data [String, Hash] JSON string or parsed hash
  # @return [Hash] Matching results with structure for review
  def match(json_data)
    data = parse_json(json_data)
    return error_result("Invalid JSON format") unless data

    unless valid_format?(data)
      return error_result("Invalid import format. Expected 'root_nodes' array.")
    end

    root_nodes = data["root_nodes"] || data[:root_nodes] || []
    match_results = []

    root_nodes.each_with_index do |root_node, index|
      match_results.concat(match_node_recursive(root_node, "#{index}", nil))
    end

    {
      success: true,
      version: data["version"] || data[:version],
      exported_at: data["exported_at"] || data[:exported_at],
      match_results: match_results,
      stats: calculate_stats(match_results)
    }
  end

  # Get available parent entities (Projects and root nodes)
  # @return [Array<MemoryEntity>] Entities that can be parents
  def available_parents
    # Return Projects and other root-level entities
    ExportStrategy.new.root_nodes
  end

  private

  def parse_json(json_data)
    case json_data
    when Hash
      json_data.deep_stringify_keys
    when String
      JSON.parse(json_data)
    else
      nil
    end
  rescue JSON::ParserError => e
    @logger.error "ImportMatchingStrategy: JSON parse error: #{e.message}"
    nil
  end

  def valid_format?(data)
    data.is_a?(Hash) && (data.key?("root_nodes") || data.key?(:root_nodes))
  end

  def error_result(message)
    {
      success: false,
      error: message,
      match_results: [],
      stats: { total: 0, root_nodes: 0, high_confidence: 0, low_confidence: 0, new: 0, skip: 0, add_relation: 0 }
    }
  end

  # Recursively match nodes in the import tree
  # @param node [Hash] The node to match
  # @param path [String] Current path in the tree
  # @param parent_name [String, nil] Name of the parent node in import data
  # @return [Array<MatchResult>] Array of match results for this node and children
  def match_node_recursive(node, path, parent_name)
    results = []
    node_name = node["name"] || node[:name]
    is_child = parent_name.present?

    # Match this node using appropriate strategy
    if is_child
      node_result = match_child_node(node, path, parent_name)
    else
      node_result = match_root_node(node, path)
    end
    results << node_result

    # Match children recursively with this node as parent
    children = node["children"] || node[:children] || []
    children.each_with_index do |child, index|
      child_path = "#{path}.children.#{index}"
      results.concat(match_node_recursive(child, child_path, node_name))
    end

    results
  end

  # Match a root node using EntitySearchStrategy (multiple potential matches)
  # @param node [Hash] The node data
  # @param path [String] Path in the import tree
  # @return [MatchResult] Match result for this node
  def match_root_node(node, path)
    name = node["name"] || node[:name]
    entity_type = node["entity_type"] || node[:entity_type]

    # Build search query from name and entity_type
    search_query = "#{name} #{entity_type}".strip
    search_results = @search_strategy.search(search_query, limit: 10)

    matches = search_results.map do |result|
      {
        entity: result.entity,
        score: result.score,
        matched_fields: result.matched_fields
      }
    end

    # Determine confidence status
    status = determine_root_status(matches, name, entity_type)

    # Auto-select best match for high confidence
    selected_match_id = nil
    if status == STATUS_HIGH_CONFIDENCE && matches.any?
      selected_match_id = matches.first[:entity].id
    end

    MatchResult.new(
      import_node: node.deep_symbolize_keys,
      matches: matches,
      status: status,
      selected_match_id: selected_match_id,
      parent_entity_id: nil,
      node_path: path,
      is_child: false,
      import_parent_name: nil,
      exact_match: nil,
      child_action: nil,
      will_add_observations: nil
    )
  end

  # Match a child node using 1:1 exact matching by name + type
  # @param node [Hash] The node data
  # @param path [String] Path in the import tree
  # @param parent_name [String] Name of the parent in import data
  # @return [MatchResult] Match result for this node
  def match_child_node(node, path, parent_name)
    name = node["name"] || node[:name]
    entity_type = node["entity_type"] || node[:entity_type]
    observations = node["observations"] || node[:observations] || []

    # Find exact match by name AND entity_type
    exact_match = MemoryEntity.find_by(name: name, entity_type: entity_type)

    if exact_match
      # Check if already has same parent
      has_same_parent = check_parent_match(exact_match.id, parent_name)

      if has_same_parent
        child_action = CHILD_ACTION_SKIP
        status = STATUS_SKIP
      else
        child_action = CHILD_ACTION_ADD_RELATION
        status = STATUS_ADD_RELATION
      end

      will_add_observations = observations.any? { |o| !observation_exists?(exact_match.id, o) }
    else
      child_action = CHILD_ACTION_CREATE
      status = STATUS_NEW
      will_add_observations = observations.any?
    end

    MatchResult.new(
      import_node: node.deep_symbolize_keys,
      matches: [],
      status: status,
      selected_match_id: exact_match&.id,
      parent_entity_id: nil,
      node_path: path,
      is_child: true,
      import_parent_name: parent_name,
      exact_match: exact_match,
      child_action: child_action,
      will_add_observations: will_add_observations
    )
  end

  # Check if an entity has a parent with the given name
  # @param entity_id [Integer] The entity ID to check
  # @param parent_name [String] The expected parent name
  # @return [Boolean] True if the entity has a parent with this name
  def check_parent_match(entity_id, parent_name)
    return false if parent_name.blank?

    # Find relations where this entity is the child (from_entity)
    parent_relations = MemoryRelation
      .where(from_entity_id: entity_id, relation_type: CHILD_RELATION_TYPES)
      .includes(:to_entity)

    parent_relations.any? do |rel|
      rel.to_entity&.name&.downcase == parent_name.downcase
    end
  end

  # Check if an observation already exists for an entity
  # @param entity_id [Integer] The entity ID
  # @param observation [Hash] The observation data
  # @return [Boolean] True if observation exists
  def observation_exists?(entity_id, observation)
    content = observation["content"] || observation[:content]
    return false if content.blank?

    MemoryObservation.exists?(memory_entity_id: entity_id, content: content)
  end

  # Determine confidence status for root nodes based on matches
  # @param matches [Array] Match results
  # @param name [String] Import node name
  # @param entity_type [String] Import node entity_type
  # @return [String] Status indicator
  def determine_root_status(matches, name, entity_type)
    return STATUS_NEW if matches.empty?

    best_match = matches.first
    score = best_match[:score]
    matched_fields = best_match[:matched_fields]

    # High confidence: score >= 20 AND matches both name (or alias) and entity_type
    if score >= HIGH_CONFIDENCE_THRESHOLD
      has_name_match = matched_fields.include?("name") || matched_fields.include?("aliases")
      has_type_match = matched_fields.include?("entity_type")

      if has_name_match && has_type_match
        # Additional check: verify entity_type is the same
        if best_match[:entity].entity_type.to_s.downcase == entity_type.to_s.downcase
          return STATUS_HIGH_CONFIDENCE
        end
      end
    end

    # Low confidence: score >= 10 AND matches entity_type
    if score >= LOW_CONFIDENCE_THRESHOLD
      if matched_fields.include?("entity_type")
        return STATUS_LOW_CONFIDENCE
      end
    end

    # Default to new if no confident match
    STATUS_NEW
  end

  # Calculate statistics for the match results
  # @param results [Array<MatchResult>] All match results
  # @return [Hash] Statistics
  def calculate_stats(results)
    {
      total: results.length,
      root_nodes: results.count { |r| !r.is_child },
      high_confidence: results.count { |r| r.status == STATUS_HIGH_CONFIDENCE },
      low_confidence: results.count { |r| r.status == STATUS_LOW_CONFIDENCE },
      new: results.count { |r| r.status == STATUS_NEW },
      skip: results.count { |r| r.status == STATUS_SKIP },
      add_relation: results.count { |r| r.status == STATUS_ADD_RELATION }
    }
  end
end
