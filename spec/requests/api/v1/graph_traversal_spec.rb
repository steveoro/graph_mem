# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Graph Traversal", type: :request do
  let!(:a) { MemoryEntity.create!(name: "Trav A", entity_type: "Project") }
  let!(:b) { MemoryEntity.create!(name: "Trav B", entity_type: "Task") }
  let!(:c) { MemoryEntity.create!(name: "Trav C", entity_type: "Task") }
  let!(:isolated) { MemoryEntity.create!(name: "Trav Isolated", entity_type: "Task") }

  let!(:r_ab) { MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of") }
  let!(:r_bc) { MemoryRelation.create!(from_entity: b, to_entity: c, relation_type: "depends_on") }

  describe "GET /api/v1/graph/traverse" do
    it "returns the bounded neighborhood with traversal metadata" do
      get "/api/v1/graph/traverse", params: { start_entity_id: a.id, max_depth: 2, direction: "outgoing" }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["entities"].map { |e| e["entity_id"] }).to eq([ a.id, b.id, c.id ])
      expect(data["relations"].map { |r| r["relation_id"] }).to contain_exactly(r_ab.id, r_bc.id)
      expect(data["traversal"]).to include(
        "start_entity_id" => a.id, "max_depth" => 2, "direction" => "outgoing", "truncated" => false
      )
    end

    it "accepts comma-separated relation_types" do
      get "/api/v1/graph/traverse", params: { start_entity_id: a.id, max_depth: 3, direction: "outgoing", relation_types: "depends_on" }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["entities"].map { |e| e["entity_id"] }).to eq([ a.id ])
    end

    it "returns 422 when start_entity_id is missing" do
      get "/api/v1/graph/traverse"
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("start_entity_id")
    end

    it "returns 404 when the start entity does not exist" do
      get "/api/v1/graph/traverse", params: { start_entity_id: 999_999 }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/graph/shortest_path" do
    it "returns the ordered shortest path" do
      get "/api/v1/graph/shortest_path", params: { from_entity_id: a.id, to_entity_id: c.id, max_depth: 3, direction: "outgoing" }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["found"]).to be(true)
      expect(data["hop_count"]).to eq(2)
      expect(data["entities"].map { |e| e["entity_id"] }).to eq([ a.id, b.id, c.id ])
      expect(data["relations"].map { |r| r["relation_id"] }).to eq([ r_ab.id, r_bc.id ])
    end

    it "returns found: false when no path exists" do
      get "/api/v1/graph/shortest_path", params: { from_entity_id: a.id, to_entity_id: isolated.id, max_depth: 5 }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["found"]).to be(false)
      expect(data["entities"]).to eq([])
    end

    it "returns 422 when an endpoint is missing" do
      get "/api/v1/graph/shortest_path", params: { from_entity_id: a.id }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 when an endpoint entity does not exist" do
      get "/api/v1/graph/shortest_path", params: { from_entity_id: a.id, to_entity_id: 999_999 }
      expect(response).to have_http_status(:not_found)
    end
  end
end
