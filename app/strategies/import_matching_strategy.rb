# frozen_string_literal: true

# Strategy class for matching imported data against existing graph entities
#
# This strategy:
# - Parses JSON import data
# - For each node, uses EntitySearchStrategy to find potential matches
# - Calculates confidence scores and status (green/yellow/grey)
# - Returns structured match results for operator review
class ImportMatchingStrategy
  # Confidence thresholds
  HIGH_CONFIDENCE_THRESHOLD = 20
  LOW_CONFIDENCE_THRESHOLD = 10

  # Status indicators
  STATUS_HIGH_CONFIDENCE = "high"    # Green - exact or near-exact match
  STATUS_LOW_CONFIDENCE = "low"      # Yellow - possible match, needs review
  STATUS_NEW = "new"                 # Grey - no match found, will be created

  # Result struct for individual node matching
  MatchResult = Struct.new(
    :import_node,        # Hash: the imported node data
    :matches,            # Array: potential existing matches with scores
    :status,             # String: high/low/new
    :selected_match_id,  # Integer: ID of selected match (nil for new)
    :parent_entity_id,   # Integer: ID of parent entity to attach to (for root imports)
    :node_path,          # String: path in import tree (e.g., "0.children.2")
    keyword_init: true
  ) do
    def to_h
      {
        import_node: {
          name: import_node[:name],
          entity_type: import_node[:entity_type],
          aliases: import_node[:aliases],
          observations_count: import_node[:observations]&.length || 0,
          children_count: import_node[:children]&.length || 0,
          relation_type: import_node[:relation_type]
        },
        matches: matches.map do |m|
          {
            entity_id: m[:entity].id,
            name: m[:entity].name,
            entity_type: m[:entity].entity_type,
            aliases: m[:entity].aliases,
            score: m[:score],
            matched_fields: m[:matched_fields]
          }
        end,
        status: status,
        selected_match_id: selected_match_id,
        parent_entity_id: parent_entity_id,
        node_path: node_path
      }
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
      match_results.concat(match_node_recursive(root_node, "#{index}"))
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
      stats: { total: 0, high_confidence: 0, low_confidence: 0, new: 0 }
    }
  end

  # Recursively match nodes in the import tree
  # @param node [Hash] The node to match
  # @param path [String] Current path in the tree
  # @return [Array<MatchResult>] Array of match results for this node and children
  def match_node_recursive(node, path)
    results = []

    # Match this node
    node_result = match_single_node(node, path)
    results << node_result

    # Match children recursively
    children = node["children"] || node[:children] || []
    children.each_with_index do |child, index|
      child_path = "#{path}.children.#{index}"
      results.concat(match_node_recursive(child, child_path))
    end

    results
  end

  # Match a single node against existing entities
  # @param node [Hash] The node data
  # @param path [String] Path in the import tree
  # @return [MatchResult] Match result for this node
  def match_single_node(node, path)
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
    status = determine_status(matches, name, entity_type)

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
      node_path: path
    )
  end

  # Determine confidence status based on matches
  # @param matches [Array] Match results
  # @param name [String] Import node name
  # @param entity_type [String] Import node entity_type
  # @return [String] Status indicator
  def determine_status(matches, name, entity_type)
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
      high_confidence: results.count { |r| r.status == STATUS_HIGH_CONFIDENCE },
      low_confidence: results.count { |r| r.status == STATUS_LOW_CONFIDENCE },
      new: results.count { |r| r.status == STATUS_NEW }
    }
  end
end
