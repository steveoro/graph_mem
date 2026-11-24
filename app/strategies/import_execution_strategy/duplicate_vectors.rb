# frozen_string_literal: true

# Before the membership lock (ImportExecutionStrategy#execute): the query vectors the semantic
# observation de-duplication will need under it (ImportObservationDuplicateDetector#precompute!),
# so the import makes no embedding call while it holds the lock.
#
# The texts are the payload's distinct, non-blank observation contents, outside excluded subtrees,
# on nodes that may land on an existing entity whose facts the detector compares semantically:
# the entity the node's merge decision names, or one with the node's name (the import resolves
# declared nodes, references and Class/Module collisions by name), holding active facts that the
# detector's rule lets it compare (compares_semantically?), and not already holding that exact text.
# The read is racy and only saves calls: the authoritative checks run under the lock, and a text it
# missed is matched exactly only, in the import's one warning.
module ImportExecutionStrategy::DuplicateVectors
  # Names and ids per IN list.
  BATCH = 1_000

  # A payload node's observation texts, and what may resolve it to an existing entity.
  DedupNode = Data.define(:name, :target_id, :texts)

  private

  # @param import_data [Hash] the payload (root_nodes)
  # @param decision_map [Hash{String => Hash}] decisions by node path
  # @return [Integer] how many texts got a vector
  def precompute_duplicate_vectors(import_data, decision_map)
    nodes = []
    roots = import_data["root_nodes"] || import_data[:root_nodes] || []
    roots.each_with_index { |root, index| collect_dedup_nodes(root, index.to_s, decision_map, nodes) }
    @observation_duplicate_detector.precompute!(dedup_texts(nodes))
  end

  # Walks the tree with process_node_recursive's paths; an excluded node's subtree is never written.
  def collect_dedup_nodes(node, path, decision_map, nodes)
    decision = decision_map[path]
    action = decision&.dig(:child_action) || decision&.dig("child_action") || decision&.dig(:action) || decision&.dig("action")
    return if action == "exclude"

    texts = Array(node[:observations] || node["observations"]).filter_map { |obs| (obs[:content] || obs["content"]).to_s.presence }
    target_id = (decision&.dig(:target_id) || decision&.dig("target_id")) if action == "merge"
    nodes << DedupNode.new(name: (node[:name] || node["name"]).to_s, target_id: target_id, texts: texts) if texts.any?
    Array(node[:children] || node["children"]).each_with_index do |child, index|
      collect_dedup_nodes(child, "#{path}.children.#{index}", decision_map, nodes)
    end
  end

  # @param nodes [Array<DedupNode>]
  # @return [Array<String>] the texts the detector may compare semantically, in payload order
  def dedup_texts(nodes)
    return [] if nodes.empty? || !EmbeddingService.vector_enabled?

    by_name = dedup_candidates(nodes.map(&:name).uniq)
    facts = comparable_facts(by_name.values.flatten | nodes.filter_map { |node| node.target_id&.to_i })
    nodes.flat_map do |node|
      ids = [ node.target_id&.to_i, *by_name[node.name.downcase] ].compact.uniq.select { |id| facts.key?(id) }
      ids.empty? ? [] : node.texts.reject { |text| ids.all? { |id| facts[id].include?(text) } }
    end
  end

  # @return [Hash{String => Array<Integer>}] entity ids by downcased name
  def dedup_candidates(names)
    names.each_slice(BATCH).flat_map { |slice| MemoryEntity.where(name: slice).pluck(:id, :name) }
         .group_by { |_id, name| name.downcase }.transform_values { |rows| rows.map(&:first) }
  end

  # @return [Hash{Integer => Set<String>}] the active contents of each entity the detector would
  #   compare semantically
  def comparable_facts(ids)
    rows = ids.each_slice(BATCH).flat_map do |slice|
      MemoryObservation.active.where(memory_entity_id: slice).pluck(:memory_entity_id, :content, :embedded_at)
    end
    rows.group_by(&:first).each_with_object({}) do |(id, facts), comparable|
      next unless @observation_duplicate_detector.compares_semantically?(facts.map(&:last))

      comparable[id] = facts.to_set { |fact| fact[1] }
    end
  end
end
