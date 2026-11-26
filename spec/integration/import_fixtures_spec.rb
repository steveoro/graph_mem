# frozen_string_literal: true

require "rails_helper"

# A GraphMem JSON export (the format the JSON import engine reads; the export and the upload were retired
# in 1.94.0) re-imported through the engine graphify:import and rails_ast:import run: the matcher, the
# headless decisions and ImportExecutionStrategy.
RSpec.describe "Graph export import fixtures", :with_test_embeddings do
  let(:baseline_fixture) { load_fixture("graph_mem_test_export.json") }
  let(:paraphrased_fixture) { load_fixture("graph_mem_test_export_2.json") }
  let(:fixture_node_count) { flatten_nodes(baseline_fixture).size }

  # Deterministic vectors below EmbeddingService#embed (spec/support/embedding_helper.rb), so every
  # call passes spec/support/embedding_lock_guard.rb and is recorded with the lock state.
  let!(:embedding_calls) { record_embedding_calls! }

  before do
    AppSettings.import_observation_duplicate_max_distance = 0.35
    seed_baseline_fixture!
  end

  it "keeps the graph_mem export fixture import-compatible" do
    expect(baseline_fixture).to include(
      "version" => "1.0",
      "exported_at" => "2026-07-31T00:00:00Z"
    )
    expect(baseline_fixture.fetch("root_nodes").first).to include(
      "name" => "graph_mem",
      "entity_type" => "Project"
    )
    expect(fixture_node_count).to eq(50)
    expect(paraphrased_observation_count).to eq(20)
  end

  it "re-imports the original export without creating graph records" do
    match_result = ImportMatchingStrategy.new.match(baseline_fixture)

    expect_all_nodes_to_match_existing_graph(match_result)

    graph_counts = graph_record_counts

    expect(import!(baseline_fixture, match_result).success).to be(true)

    expect(graph_record_counts).to eq(graph_counts)
  end

  it "suppresses paraphrased observations through semantic de-duplication" do
    match_result = ImportMatchingStrategy.new.match(paraphrased_fixture)

    expect_all_nodes_to_match_existing_graph(match_result)
    child_results = match_result.fetch(:match_results).select(&:is_child)
    expect(child_results).to all(have_attributes(will_add_observations: false))

    graph_counts = graph_record_counts
    embedding_calls.clear

    expect(import!(paraphrased_fixture, match_result).success).to be(true)

    expect(graph_record_counts).to eq(graph_counts)
    # The paraphrases were embedded before the import took the membership lock (each distinct text
    # once), none under it.
    expect(embedding_calls.map { |call| call[:text] }).to match_array(paraphrased_contents.uniq)
    expect(embedding_calls).to all(include(held: false, lock_free: true))
  end

  it "rejects paraphrased imports when embeddings are unavailable, in the match and in the execute, writing nothing" do
    match_result = ImportMatchingStrategy.new.match(baseline_fixture) # the same tree, matched while embeddings run
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

    expect { ImportMatchingStrategy.new.match(paraphrased_fixture) }
      .to raise_error(ImportObservationDuplicateDetector::UnavailableError, /semantic observation de-duplication cannot run/)
    report = nil
    expect { report = import!(paraphrased_fixture, match_result) }.not_to(change { graph_record_counts })
    expect(report.success).to be(false)
    expect(report.errors.join).to include("de-duplication")
  end

  private

  def load_fixture(filename)
    JSON.parse(File.read(Rails.root.join("spec/fixtures/files", filename)))
  end

  def flatten_nodes(data)
    nodes = []
    walk = nil
    walk = lambda do |node|
      nodes << node
      node.fetch("children", []).each { |child| walk.call(child) }
    end
    data.fetch("root_nodes").each { |root| walk.call(root) }
    nodes
  end

  def paraphrased_contents
    flatten_nodes(paraphrased_fixture)
      .flat_map { |node| node.fetch("observations", []) }
      .map { |observation| observation.fetch("content") }
      .select { |content| content.start_with?("Restated: ") }
  end

  def paraphrased_observation_count = paraphrased_contents.size

  def graph_record_counts
    {
      entities: MemoryEntity.count,
      observations: MemoryObservation.count,
      relations: MemoryRelation.count
    }
  end

  def seed_baseline_fixture!
    expect(import!(baseline_fixture, ImportMatchingStrategy.new.match(baseline_fixture)).success).to be(true)
    # Imports defer embeddings to the maintenance backfill (inline embedding
    # is suppressed during execute). Run the backfill now — the deterministic
    # test embeddings make it instant — so subsequent imports can run
    # semantic observation de-duplication instead of failing on unembedded rows.
    EmbeddingService.backfill_all
  end

  # Executes the import as graphify:import and rails_ast:import do: the matcher's results turned into
  # headless decisions.
  # @return [ImportExecutionStrategy::ImportReport]
  def import!(data, match_result)
    decisions = GraphifyImporter.headless_decisions(match_result.fetch(:match_results))
    ImportExecutionStrategy.new.execute(data, decisions)
  end

  def expect_all_nodes_to_match_existing_graph(match_result)
    expect(match_result.fetch(:success)).to be true
    expect(match_result.fetch(:stats)).to include(
      total: fixture_node_count,
      root_nodes: 1,
      high_confidence: 1,
      new: 0,
      skip: fixture_node_count - 1,
      add_relation: 0
    )

    root_result = match_result.fetch(:match_results).find { |result| !result.is_child }
    expect(root_result).to have_attributes(status: "high", selected_match_id: be_present)

    match_result.fetch(:match_results).select(&:is_child).each do |result|
      expect(result).to have_attributes(status: "skip", child_action: "skip")
    end
  end
end
