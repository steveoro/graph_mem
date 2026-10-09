# frozen_string_literal: true

namespace :graphify do
  desc "Translate a Graphify graph.json into a graph_mem import file (GRAPH=…, PROJECT=..., OUT=...)"
  task translate: :environment do
    path = ENV["GRAPH"].presence || abort("GRAPH is required (location of graph.json)")
    project = ENV["PROJECT"].presence || File.basename(File.dirname(File.expand_path(path))).presence ||
              abort("PROJECT is required (name of the root Project entity)")
    out = ENV["OUT"].presence || "graph_mem_import.json"

    result = GraphifyImporter.new(File.read(path), project_name: project).translate
    payload = result.import_data.merge("ambiguous_relations" => result.ambiguous_relations)
    # max_nesting: false — pretty_generate's 100-level default raises
    # JSON::NestingError on trees deeper than ~49 levels (2 JSON levels per
    # tree level); the translator itself caps depth at MAX_TREE_DEPTH.
    File.write(out, JSON.pretty_generate(payload, max_nesting: false))

    puts "Wrote #{out}"
    puts "Stats: #{result.stats.to_json}"
    puts "Ambiguous relations withheld for review: #{result.ambiguous_relations.size}"
    puts "Upload #{out} via Data Exchange → Import to review and apply; " \
         "ambiguous edges are queued to scan_review after a successful execute."
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

    decisions = GraphifyImporter.headless_decisions(match_result[:match_results])

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

    # The import deferred row embeddings — backfill synchronously now so the
    # next import's matching step (and every vector read) sees real vectors
    # even when the maintenance job worker is not running.
    begin
      backfilled = EmbeddingService.backfill_all
      puts "Embedding backfill: #{backfilled.to_json}"
    rescue StandardError => e
      warn "Embedding backfill skipped (#{e.class}: #{e.message}) — run rake embeddings:backfill"
    end

    rows = GraphifyImporter.seed_ambiguous_relations(result.ambiguous_relations, project)
    puts "Queued #{rows.size} ambiguous relation(s) for review (scan_review)." if rows.any?
  end
end
