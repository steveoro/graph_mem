# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe "Graph export import fixtures", :with_test_embeddings, type: :request do
  let(:baseline_fixture) { load_fixture("graph_mem_test_export.json") }
  let(:paraphrased_fixture) { load_fixture("graph_mem_test_export_2.json") }
  let(:fixture_node_count) { flatten_nodes(baseline_fixture).size }

  before do
    sign_in_operator
    AppSettings.import_observation_duplicate_max_distance = 0.35
    configure_test_embeddings!
    seed_baseline_fixture!
  end

  after do
    delete import_cancel_data_exchange_index_path
  end

  it "keeps the graph_mem export fixture import-compatible" do
    expect(baseline_fixture).to include(
      "version" => ExportStrategy::FORMAT_VERSION,
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

    execute_import!

    expect(graph_record_counts).to eq(graph_counts)
  end

  it "rejects paraphrased imports when embeddings are unavailable" do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

    file = Rack::Test::UploadedFile.new(
      StringIO.new(JSON.generate(paraphrased_fixture)),
      "application/json",
      original_filename: "graph_mem_test_export_2.json"
    )
    post import_upload_data_exchange_index_path, params: { file: file }

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(flash[:error]).to include("requires the embedding service")
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

  def paraphrased_observation_count
    flatten_nodes(paraphrased_fixture)
      .flat_map { |node| node.fetch("observations", []) }
      .count { |observation| observation.fetch("content").start_with?("Restated: ") }
  end

  def graph_record_counts
    {
      entities: MemoryEntity.count,
      observations: MemoryObservation.count,
      relations: MemoryRelation.count
    }
  end

  def configure_test_embeddings!
    service = EmbeddingService.new(
      config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }
    )
    allow(service).to receive(:embed) { |content| deterministic_embedding(content) }
    allow(service).to receive(:embed!) { |content| deterministic_embedding(content) }
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(service)
  end

  def deterministic_embedding(content)
    canonical_content = content.to_s.delete_prefix("Restated: ")
    index = Digest::SHA256.hexdigest(canonical_content).to_i(16) % 768
    Array.new(768, 0.0).tap { |vector| vector[index] = 1.0 }
  end

  def seed_baseline_fixture!
    upload_fixture!(baseline_fixture, "graph_mem_test_export.json")
    execute_import!
    delete import_cancel_data_exchange_index_path
  end

  def upload_fixture!(data, filename)
    file = Rack::Test::UploadedFile.new(
      StringIO.new(JSON.generate(data)),
      "application/json",
      original_filename: filename
    )
    post import_upload_data_exchange_index_path, params: { file: file }
    expect(response).to redirect_to(import_review_data_exchange_index_path)
  end

  def execute_import!
    post import_execute_data_exchange_index_path, params: { decisions: {} }
    expect(response).to redirect_to(import_report_data_exchange_index_path)
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
