# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Graph export import fixtures", :with_test_embeddings, type: :request do
  let(:baseline_fixture) { load_fixture("graph_mem_test_export.json") }
  let(:paraphrased_fixture) { load_fixture("graph_mem_test_export_2.json") }
  let(:fixture_node_count) { flatten_nodes(baseline_fixture).size }

  # Deterministic vectors below EmbeddingService#embed (spec/support/embedding_helper.rb), so every
  # call passes spec/support/embedding_lock_guard.rb and is recorded with the lock state.
  let!(:embedding_calls) { record_embedding_calls! }

  before do
    sign_in_operator
    AppSettings.import_observation_duplicate_max_distance = 0.35
    seed_baseline_fixture!
  end

  after do
    ImportSession.cleanup(@session_id) if @session_id
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

    upload_fixture!(baseline_fixture, "graph_mem_test_export.json")
    graph_counts = graph_record_counts

    execute_import!

    expect(graph_record_counts).to eq(graph_counts)
  end

  it "suppresses paraphrased observations through semantic de-duplication" do
    match_result = ImportMatchingStrategy.new.match(paraphrased_fixture)

    expect_all_nodes_to_match_existing_graph(match_result)
    child_results = match_result.fetch(:match_results).select(&:is_child)
    expect(child_results).to all(have_attributes(will_add_observations: false))

    upload_fixture!(paraphrased_fixture, "graph_mem_test_export_2.json")
    graph_counts = graph_record_counts
    embedding_calls.clear

    execute_import!

    expect(graph_record_counts).to eq(graph_counts)
    # The paraphrases were embedded before the import took the membership lock (each distinct text
    # once), none under it.
    expect(embedding_calls.map { |call| call[:text] }).to match_array(paraphrased_contents.uniq)
    expect(embedding_calls).to all(include(held: false, lock_free: true))
  end

  it "rejects paraphrased imports when embeddings are unavailable" do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

    file = Rack::Test::UploadedFile.new(
      StringIO.new(JSON.generate(paraphrased_fixture)),
      "application/json",
      original_filename: "graph_mem_test_export_2.json"
    )
    post projects_imports_path, params: { file: file }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("requires the embedding service")
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
    upload_fixture!(baseline_fixture, "graph_mem_test_export.json")
    execute_import!
    # Imports defer embeddings to the maintenance backfill (inline embedding
    # is suppressed during execute). Run the backfill now — the deterministic
    # test embeddings make it instant — so subsequent imports can run
    # semantic observation de-duplication instead of failing on unembedded rows.
    EmbeddingService.backfill_all
  end

  def upload_fixture!(data, filename)
    file = Rack::Test::UploadedFile.new(
      StringIO.new(JSON.generate(data)),
      "application/json",
      original_filename: filename
    )
    post projects_imports_path, params: { file: file }
    expect(response).to redirect_to(%r{/projects/imports/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z})
    @session_id = response.location[%r{/projects/imports/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}, 1]
  end

  def execute_import!
    post execute_projects_import_path(@session_id), params: { decisions: {} }
    expect(response).to redirect_to(%r{/projects/imports/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/report\z})
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
