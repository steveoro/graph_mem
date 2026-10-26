# frozen_string_literal: true

require "rails_helper"

# A guest browser session reaches only ApiAuthentication::GUEST_READ_ACTIONS (UI-1).
RSpec.describe "API v1 guest access", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:observation) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.") }
  let!(:relation) { MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of") }
  let(:json) { { "Accept" => "application/json" } }

  def record_counts
    [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count, AuditLog.count, MaintenanceReportRow.count ]
  end

  before do
    enable_guest!
    sign_in_guest
  end

  it "serves every guest read action" do
    {
      "/api/v1/graph_data" => {},
      "/api/v1/memory_entities" => {},
      "/api/v1/memory_entities/#{widget.id}" => {},
      "/api/v1/memory_entities/search" => { q: "SynthWidget" },
      "/api/v1/memory_entities/#{widget.id}/memory_observations" => {},
      "/api/v1/memory_entities/#{widget.id}/memory_observations/#{observation.id}" => {},
      "/api/v1/memory_relations" => {},
      "/api/v1/memory_relations/#{relation.id}" => {},
      "/api/v1/search/subgraph" => { q: "SynthWidget" },
      "/api/v1/graph/traverse" => { start_entity_id: widget.id },
      "/api/v1/graph/shortest_path" => { from_entity_id: widget.id, to_entity_id: project.id }
    }.each do |path, params|
      get path, params: params, headers: json
      expect(response).to have_http_status(:ok), "#{path} → #{response.status}: #{response.body.truncate(200)}"
    end
  end

  it "refuses every write and every other read with 403 JSON, changing nothing" do
    counts = record_counts
    [
      [ :post, "/api/v1/memory_entities", { memory_entity: { name: "Intruder", entity_type: "Task" } } ],
      [ :patch, "/api/v1/memory_entities/#{widget.id}", { memory_entity: { name: "Renamed" } } ],
      [ :delete, "/api/v1/memory_entities/#{widget.id}", {} ],
      [ :post, "/api/v1/memory_entities/#{widget.id}/merge_into/#{project.id}", {} ],
      [ :post, "/api/v1/memory_relations", { memory_relation: { from_entity_id: project.id, to_entity_id: widget.id, relation_type: "depends_on" } } ],
      [ :delete, "/api/v1/memory_entities/#{widget.id}/memory_observations/delete_duplicates", {} ],
      [ :post, "/api/v1/search/subgraph_by_ids", { entity_ids: [ widget.id ] } ],
      [ :post, "/api/v1/summarize", { entity_ids: [ widget.id ] } ],
      [ :post, "/api/v1/scan", { path: "/tmp" } ],
      [ :post, "/api/v1/bulk", { operations: [] } ],
      [ :get, "/api/v1/context", {} ],
      [ :post, "/api/v1/context", { project_id: project.id } ],
      [ :delete, "/api/v1/context", {} ],
      [ :get, "/api/v1/maintenance/stats", {} ]
    ].each do |verb, path, params|
      process verb, path, params: params, headers: json
      expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} → #{response.status}"
      expect(response.parsed_body).to eq("error" => "forbidden", "role" => "guest")
    end
    expect(record_counts).to eq(counts)
  end

  it "gives a guest session plus a valid bearer token full access" do
    ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
    get "/api/v1/maintenance/stats", headers: json.merge("Authorization" => "Bearer synthetic-token")

    expect(response).to have_http_status(:ok)
  ensure
    ENV.delete("GRAPH_MEM_MCP_TOKEN")
  end

  it "answers an expired guest session with 401" do
    travel_to((ApplicationController::GUEST_IDLE_TIMEOUT + 1.minute).from_now) do
      get "/api/v1/graph_data", headers: json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "answers a guest session whose access was withdrawn with 401" do
    AppSettings.enable_guest_access = false

    get "/api/v1/graph_data", headers: json

    expect(response).to have_http_status(:unauthorized)
  ensure
    AppSettings.enable_guest_access = true
  end
end
