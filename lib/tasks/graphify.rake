# frozen_string_literal: true

namespace :graphify do
  desc "Translate a Graphify graph.json into a graph_mem import file (GRAPH=…, PROJECT=..., OUT=...)"
  task translate: :environment do
    path = ENV["GRAPH"].presence || abort("GRAPH is required (location of graph.json)")
    project = ENV["PROJECT"].presence || File.basename(File.dirname(File.expand_path(path))).presence ||
              abort("PROJECT is required (name of the root Project entity)")
    out = ENV["OUT"].presence || "graph_mem_import.json"

    result = GraphifyImporter.new(File.read(path), project_name: project).translate
    File.write(out, JSON.pretty_generate(result.import_data))

    puts "Wrote #{out}"
    puts "Stats: #{result.stats.to_json}"
    puts "Ambiguous relations withheld for review: #{result.ambiguous_relations.size}"
    puts "Upload #{out} via Data Exchange → Import to review and apply."
  end

  desc "Headless Graphify import: match, auto-accept, execute (GRAPH=…, PROJECT=...)"
  task import: :environment do
    path = ENV["GRAPH"].presence || abort("GRAPH is required (location of graph.json)")
    project = ENV["PROJECT"].presence || File.basename(File.dirname(File.expand_path(path))).presence ||
              abort("PROJECT is required (name of the root Project entity)")

    result = GraphifyImporter.new(File.read(path), project_name: project).translate
    puts "Translated: #{result.stats.to_json}"

    match_result = ImportMatchingStrategy.new.match(result.import_data)
    abort "Matching failed: #{match_result[:error]}" unless match_result[:success]

    decisions = match_result[:match_results].map do |match|
      if match.is_child
        { node_path: match.node_path, child_action: match.child_action }
      elsif match.selected_match_id
        { node_path: match.node_path, action: "merge", target_id: match.selected_match_id }
      else
        { node_path: match.node_path, action: "create" }
      end
    end

    total = result.stats[:nodes_imported]
    operation = OperationProgress.start!(
      operation_type: "import",
      total_count: total,
      message: "Graphify import of #{project}"
    )
    tracker = OperationProgressTracker.new(operation_progress: operation, total: total, message: "Graphify import")
    report = ImportExecutionStrategy.new(progress_tracker: tracker).execute(result.import_data, decisions)

    puts "Import report: #{report.to_h.except(:errors).to_json}"
    puts "Errors: #{report.errors.to_json}" if report.errors.any?
    abort "Import failed" unless report.success

    seed_ambiguous_relations(result.ambiguous_relations, project)
  end
end

# Queues AMBIGUOUS-confidence edges as relationship_proposal review items in
# the scan_review queue. Edges whose endpoints did not materialize are skipped.
def seed_ambiguous_relations(ambiguous, project)
  return if ambiguous.blank?

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
  return if items.empty?

  rows = CompactionReviewService.seed_report(
    report_type: "scan_review",
    source: "graphify",
    source_ref: project,
    items: items
  )
  puts "Queued #{rows.size} ambiguous relation(s) for review (scan_review)."
end
