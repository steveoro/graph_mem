# frozen_string_literal: true

# Translates a Graphify `graph.json` (NetworkX node-link format, schema_version 1)
# into graph_mem's import-tree payload so the existing matching/execution/review
# pipeline can ingest a code-derived structure graph.
#
# Tree shape (containment edges collapse to `part_of`):
#
#   Project (repo root)
#   └─ File (one per source file)
#      └─ Class / Module (via `contains`)
#         └─ Method / Constant (via `method`, `defines`)
#
# Non-tree edges (`calls`, `inherits`, `mixes_in`, `imports_from`,
# `indirect_call`) become entries in `relations`, applied as a second pass
# after entities exist. AMBIGUOUS edges are never auto-applied: they are
# returned separately so the caller can queue them for review.
#
# Pure JSON transform — no LLM, no DB access beyond reading nothing.
class GraphifyImporter
  # Graphify link relations that define the containment tree.
  CONTAINMENT_RELATIONS = %w[contains method defines].freeze

  # Graphify link relations mapped to canonical code edges.
  EDGE_RELATION_MAPPINGS = {
    "calls" => "calls",
    "indirect_call" => "calls",
    "inherits" => "inherits",
    "mixes_in" => "mixes_in",
    "imports_from" => "depends_on"
  }.freeze

  AMBIGUOUS_CONFIDENCE = "AMBIGUOUS"
  SOURCE_NAME = "graphify"

  Result = Struct.new(
    :import_data,           # Hash: {version, exported_at, root_nodes: [...], relations: [...]}
    :ambiguous_relations,   # Array<Hash>: edges withheld for review
    :stats,                 # Hash: counts for reporting
    keyword_init: true
  )

  # Queues withheld AMBIGUOUS edges as `relationship_proposal` items in the
  # scan_review queue. Edges whose endpoints did not materialize (or that
  # already exist as relations) are skipped. Shared by the headless rake
  # import and the Data Exchange execute path.
  # @param ambiguous [Array<Hash>] edge hashes from Result#ambiguous_relations
  # @param source_ref [String] report source_ref (project name)
  # @return [Array] seeded review rows
  def self.seed_ambiguous_relations(ambiguous, source_ref)
    return [] if ambiguous.blank?

    items = ambiguous.filter_map do |relation|
      from = ImportEntityResolver.find_by_name_and_type(relation["from_name"], relation["from_type"])
      to = ImportEntityResolver.find_by_name_and_type(relation["to_name"], relation["to_type"])
      next unless from && to
      next if from.id == to.id
      next if MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id,
                                     relation_type: relation["relation_type"])

      props = relation["properties"] || {}
      {
        id: SecureRandom.uuid,
        kind: "relationship_proposal",
        from_entity_id: from.id,
        from_name: from.name,
        from_entity_type: from.entity_type,
        to_entity_id: to.id,
        to_name: to.name,
        to_entity_type: to.entity_type,
        relation_type: relation["relation_type"],
        confidence_band: "low",
        score: (relation["confidence"].to_f * 10).round,
        supporting_observation_ids: [],
        explanation: "Graphify AMBIGUOUS edge in #{props['source_file']}#{props['source_location']}",
        evidence_terms: [ props["context"] ].compact
      }
    end
    return [] if items.empty?

    CompactionReviewService.seed_report(
      report_type: "scan_review",
      source: SOURCE_NAME,
      source_ref: source_ref,
      items: items
    )
  end

  # Auto-accept decision map for headless imports. Mirrors operator review:
  # root nodes merge into their selected match (or create), children take the
  # matcher-suggested action — except `add_relation` on a child that already
  # has a `part_of` parent, which would silently steal the entity from another
  # project's tree. Unattended imports never re-parent: downgrade to `skip`
  # (entity stays put; its observations still import). Operators keep full
  # re-parent rights through explicit Import Review decisions.
  # @param match_results [Array<ImportMatchingStrategy::MatchResult>]
  # @return [Array<Hash>] decisions for ImportExecutionStrategy#execute
  def self.headless_decisions(match_results)
    by_path = match_results.index_by(&:node_path)
    foreign_paths = foreign_subtree_paths(match_results, by_path)

    match_results.map do |match|
      if match.is_child
        child_action = match.child_action
        if child_action == "add_relation" && already_parented?(match.exact_match)
          child_action = "skip"
        end
        # A child parented under a DIFFERENT entity than this import's parent
        # node belongs to another project's tree: skip it AND its whole
        # subtree, otherwise new descendants would attach under the foreign
        # entity and contaminate that project's structure.
        child_action = "skip" if inside_any?(match.node_path, foreign_paths)
        { node_path: match.node_path, child_action: child_action }
      elsif match.selected_match_id
        { node_path: match.node_path, action: "merge", target_id: match.selected_match_id }
      else
        { node_path: match.node_path, action: "create" }
      end
    end
  end

  def self.already_parented?(entity)
    entity.present? && MemoryRelation.exists?(from_entity_id: entity.id, relation_type: "part_of")
  end
  private_class_method :already_parented?

  # Paths of children whose matched entity already has a `part_of` parent
  # that is NOT the entity this import would attach under (when the import
  # parent resolves to a different entity — or creates a fresh one — the
  # match's real parent belongs to another tree).
  def self.foreign_subtree_paths(match_results, by_path)
    match_results.each_with_object(Set.new) do |match, foreign|
      next unless match.is_child && already_parented?(match.exact_match)

      parent_path = match.node_path.sub(/\.children\.\d+\z/, "")
      parent_match = by_path[parent_path]
      expected_id = parent_match&.exact_match&.id || parent_match&.selected_match_id
      actual_id = MemoryRelation.where(from_entity_id: match.exact_match.id,
                                       relation_type: "part_of").pick(:to_entity_id)
      foreign << match.node_path unless expected_id.present? && expected_id == actual_id
    end
  end
  private_class_method :foreign_subtree_paths

  # True when `path` equals or descends from any path in `ancestors`
  # (descendants look like "<path>.children.N[.children.M...]").
  def self.inside_any?(path, ancestors)
    return false if ancestors.empty?

    current = path
    while (idx = current.rindex(".children."))
      return true if ancestors.include?(current)
      current = current[0...idx]
    end
    ancestors.include?(current)
  end
  private_class_method :inside_any?

  # @param graph_data [Hash, String] parsed graph.json or raw JSON string
  # @param project_name [String] name of the root Project entity
  def initialize(graph_data, project_name:)
    @data = graph_data.is_a?(String) ? JSON.parse(graph_data) : graph_data
    @project_name = project_name
    @nodes = {}
    @edges = []
  end

  # @return [Result]
  def translate
    index_nodes
    build_entity_names
    tree = build_tree
    relations, ambiguous = build_relations

    Result.new(
      import_data: {
        "version" => "1.0",
        "exported_at" => Time.current.iso8601,
        "root_nodes" => [ tree ],
        "relations" => relations
      },
      ambiguous_relations: ambiguous,
      stats: build_stats(relations, ambiguous)
    )
  end

  private

  def index_nodes
    (@data["nodes"] || []).each do |node|
      @nodes[node["id"]] = node unless external_node?(node)
    end
    @edges = (@data["links"] || @data["edges"] || [])
  end

  def external_node?(node)
    node["type"] == "external" || node["external"] == true
  end

  # Assigns each importable node its entity name + type. Method labels in
  # graph.json are unqualified (".call()") — they are qualified with their
  # containing class/module so name+type matching stays collision-free.
  def build_entity_names
    @entity_info = {}
    parents = containment_parents

    @nodes.each do |id, node|
      info = classify(node)
      next unless info

      @entity_info[id] = info
    end

    # Second pass: qualify method names once all owners are classified.
    @entity_info.each do |id, info|
      next unless info[:entity_type] == "Method" && info[:unqualified]

      owner = parents[id] && @entity_info[parents[id]]
      info[:name] = "#{owner ? owner[:name] : file_base_name(node_file(id))}##{info[:unqualified]}"
      info.delete(:unqualified)
    end
  end

  def classify(node)
    label = node["label"].to_s
    return nil if label.blank?

    source_file = node["source_file"].to_s

    if file_node?(node, label, source_file)
      return { name: file_display_name(source_file, label), entity_type: "File" }
    end

    if method_node?(node, label)
      # Bare placeholder; qualified with the owner name in the second pass.
      bare = label.sub(/\A\.+/, "").sub(/\(\)\z/, "").sub(/\Aself\./, "")
      return { name: bare, entity_type: "Method", unqualified: bare }
    end

    if constant_node?(label)
      return { name: label, entity_type: "Constant" }
    end

    # Class-likes and everything else callable land here. Ruby modules cannot be
    # told apart from classes in graph.json — Class covers both.
    { name: label, entity_type: "Class" }
  end

  def file_node?(node, label, source_file)
    return true if source_file.present? && File.basename(source_file) == label

    label.match?(/\.(rb|py|js|jsx|ts|tsx|sql|rake|gemspec|sh|yml|yaml|json|erb|haml|slim|css|scss)\z/i)
  end

  def method_node?(node, label)
    return true if label.start_with?(".") || label.end_with?("()")

    snake_case_callable?(node, label)
  end

  # Snake-case callables reached via `defines`/`method` edges (e.g. bin scripts).
  def snake_case_callable?(node, label)
    node["_callable"] == true && label.match?(/\A[a-z_][a-z0-9_]*[!?=]?\z/) && !label.include?("::")
  end

  def constant_node?(label)
    label.match?(/\A[A-Z][A-Z0-9_]*\z/) && label.length > 1
  end

  # Maps each node id to the source id of its single containment edge.
  def containment_parents
    @containment_parents ||= {}.tap do |parents|
      @edges.each do |edge|
        next unless CONTAINMENT_RELATIONS.include?(edge["relation"].to_s)

        child = edge["target"]
        parent = edge["source"]
        next unless @nodes.key?(child) && @nodes.key?(parent)
        next if parents.key?(child)

        parents[child] = parent
      end
    end
  end

  def node_file(id)
    @nodes.dig(id, "source_file").to_s
  end

  def file_base_name(path)
    base = File.basename(path.to_s, ".*")
    base.presence || "top_level"
  end

  def file_display_name(source_file, label)
    source_file.presence || label
  end

  # Builds Project → File → Class/Module → Method/Constant tree.
  # Nodes without a classified containment parent hang off the project root
  # so nothing referenced by an edge is lost.
  def build_tree
    parents = containment_parents
    children_of = Hash.new { |hash, key| hash[key] = [] }
    roots = []

    @entity_info.each_key do |id|
      parent_id = parents[id]
      if parent_id && @entity_info.key?(parent_id)
        children_of[parent_id] << id
      else
        roots << id
      end
    end

    file_roots = roots.select { |id| @entity_info[id][:entity_type] == "File" }
                    .sort_by { |id| @entity_info[id][:name] }
    other_roots = (roots - file_roots).sort_by { |id| @entity_info[id][:name] }

    {
      "name" => @project_name,
      "entity_type" => "Project",
      "observations" => [ provenance_observation(graph_meta_line) ],
      "children" => (file_roots + other_roots).map { |id| import_subtree(id, children_of) }
    }
  end

  def import_subtree(id, children_of)
    node = import_node(id)
    children_of[id].sort_by { |child_id| @entity_info[child_id][:name] }.each do |child_id|
      node["children"] << import_subtree(child_id, children_of)
    end
    node
  end

  def import_node(id)
    info = @entity_info[id]
    node = @nodes[id]
    {
      "name" => info[:name],
      "entity_type" => info[:entity_type],
      "relation_type" => "part_of",
      "observations" => entity_observations(node),
      "children" => []
    }
  end

  def entity_observations(node)
    file = node["source_file"].to_s
    line = node["source_location"].to_s
    return [] if file.blank?

    [ provenance_observation("Defined at #{file}#{line}") ]
  end

  def provenance_observation(content)
    {
      "content" => content,
      "source" => SOURCE_NAME,
      "confidence" => 1.0,
      "tags" => [ "graphify", "provenance" ]
    }
  end

  def graph_meta_line
    meta = @data["graph"] || {}
    parts = [ "Imported from graph.json" ]
    parts << "graphify #{meta['graphify_version']}" if meta["graphify_version"]
    parts << "schema #{meta['schema_version']}" if meta["schema_version"]
    parts << "commit #{@data['built_at_commit']}" if @data["built_at_commit"]
    parts.join(", ")
  end

  # Every non-containment edge becomes a name+type-addressed relation.
  # Endpoints resolve to the names assigned during classification, so
  # ImportExecutionStrategy can find them with ImportEntityResolver.
  def build_relations
    relations = {}
    ambiguous = []
    @unresolved_edges = 0

    @edges.each do |edge|
      kind = edge["relation"].to_s
      canonical = EDGE_RELATION_MAPPINGS[kind]
      next unless canonical

      from = @entity_info[edge["source"]]
      to = @entity_info[edge["target"]]
      unless from && to
        @unresolved_edges += 1 # external/skipped endpoint
        next
      end

      relation = {
        "from_name" => from[:name],
        "from_type" => from[:entity_type],
        "to_name" => to[:name],
        "to_type" => to[:entity_type],
        "relation_type" => canonical,
        "weight" => edge["weight"],
        "confidence" => edge["confidence_score"],
        "properties" => {
          "source" => SOURCE_NAME,
          "provenance" => edge["confidence"],
          "source_file" => edge["source_file"],
          "source_location" => edge["source_location"],
          "context" => edge["context"],
          "graphify_relation" => kind
        }.compact
      }

      if edge["confidence"].to_s.upcase == AMBIGUOUS_CONFIDENCE
        ambiguous << relation
        next
      end

      key = [ relation["from_name"], relation["from_type"], relation["to_name"], relation["to_type"], canonical ]
      existing = relations[key]
      relations[key] = relation if existing.nil? || relation["confidence"].to_f > existing["confidence"].to_f
    end

    [ relations.values, ambiguous ]
  end

  def build_stats(relations, ambiguous)
    mapped = @edges.count { |edge| EDGE_RELATION_MAPPINGS.key?(edge["relation"].to_s) }

    {
      nodes_total: (@data["nodes"] || []).size,
      nodes_imported: @entity_info.size,
      nodes_skipped_external: (@data["nodes"] || []).size - @nodes.size,
      nodes_unclassified: @nodes.size - @entity_info.size,
      edges_total: @edges.size,
      edges_containment: @edges.count { |edge| CONTAINMENT_RELATIONS.include?(edge["relation"].to_s) },
      relations_emitted: relations.size,
      relations_ambiguous: ambiguous.size,
      relations_dropped_unresolved: @unresolved_edges || 0,
      relations_deduped: mapped - relations.size - ambiguous.size - (@unresolved_edges || 0),
      relations_unmapped: @edges.size -
        @edges.count { |edge| CONTAINMENT_RELATIONS.include?(edge["relation"].to_s) } - mapped
    }
  end
end
