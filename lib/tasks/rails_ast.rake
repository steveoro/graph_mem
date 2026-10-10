# frozen_string_literal: true

namespace :rails_ast do
  desc "Extract a Rails app's code graph into graph.json (REPO=…, PROJECT=..., OUT=...)"
  task extract: :environment do
    repo = ENV["REPO"].presence || abort("REPO is required (path to the Rails app)")
    project = ENV["PROJECT"].presence || File.basename(File.expand_path(repo))
    out = ENV["OUT"].presence || "rails_ast_graph.json"

    result = RailsAstExtractor.extract(repo, project_name: project)
    File.write(out, JSON.pretty_generate(result, max_nesting: false))
    puts "Wrote #{out} (#{result['nodes'].size} nodes, #{result['links'].size} links)"
    puts "Stats: #{result['stats'].to_json}"
  end

  desc "Extract + headless import a Rails app's code graph (REPO=…, PROJECT=..., RESCAN=0 opts out)"
  task import: :environment do
    repo = ENV["REPO"].presence || abort("REPO is required (path to the Rails app)")
    project = ENV["PROJECT"].presence || File.basename(File.expand_path(repo))

    extracted = RailsAstExtractor.extract(repo, project_name: project)
    puts "Extracted: #{extracted['nodes'].size} nodes, #{extracted['links'].size} links — #{extracted['stats'].to_json}"

    result = GraphifyImporter.new(JSON.generate(extracted, max_nesting: false),
                                  project_name: project).translate
    puts "Translated: #{result.stats.to_json}"

    # RESCAN=0 opts out of the incremental-rescan pass (same contract as
    # graphify:import — the extractor's output is trusted to be the full
    # repo scan of the directories it covers).
    if ENV["RESCAN"] == "0"
      result.import_data.delete("rescan")
      puts "RESCAN=0: rescan pass disabled for this run."
    end

    match_result = ImportMatchingStrategy.new.match(result.import_data)
    abort "Matching failed: #{match_result[:error]}" unless match_result[:success]

    decisions = GraphifyImporter.headless_decisions(match_result[:match_results])

    total = result.stats[:nodes_imported]
    operation = OperationProgress.start!(
      operation_type: "import",
      total_count: total,
      message: "Rails AST import of #{project}"
    )
    tracker = OperationProgressTracker.new(operation_progress: operation, total: total,
                                           message: "Rails AST import")
    report = ImportExecutionStrategy.new(progress_tracker: tracker).execute(result.import_data, decisions)

    puts "Import report: #{report.to_h.except(:errors).to_json}"
    puts "Errors: #{report.errors.to_json}" if report.errors.any?
    abort "Import failed" unless report.success
  end
end
