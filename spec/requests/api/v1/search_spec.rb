# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Search", type: :request do
  let!(:entity_a) { MemoryEntity.create!(name: "XqzAlphaZqx", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "XqzBetaZqx", entity_type: "Task") }
  let!(:obs_a) { MemoryObservation.create!(memory_entity: entity_a, content: "Alpha observation") }
  let!(:obs_b) { MemoryObservation.create!(memory_entity: entity_b, content: "Beta observation") }

  before do
    allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([])
  end

  describe "GET /api/v1/search/subgraph" do
    it "returns matching entities and relations" do
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")

      get "/api/v1/search/subgraph", params: { q: "XqzAlpha" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      entity_ids = data["entities"].map { |e| e["entity_id"] }
      expect(entity_ids).to include(entity_a.id)
      expect(data).to have_key("pagination")
    end

    it "returns 422 when q is missing" do
      get "/api/v1/search/subgraph"
      expect(response).to have_http_status(:unprocessable_content)
      data = JSON.parse(response.body)
      expect(data["error"]).to include("q parameter")
    end

    it "searches in observations when search_in_observations is true" do
      get "/api/v1/search/subgraph", params: { q: "XqzAlpha" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      entity_ids = data["entities"].map { |e| e["entity_id"] }
      expect(entity_ids).to include(entity_a.id)
    end

    it "supports pagination via page and per_page" do
      get "/api/v1/search/subgraph", params: { q: "Xqz", per_page: 1, page: 1 }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["entities"].length).to eq(1)
      expect(data["pagination"]["per_page"]).to eq(1)
      expect(data["pagination"]["total_entities"]).to eq(2)
    end

    it "returns 422 when all search fields are disabled" do
      get "/api/v1/search/subgraph", params: {
        q: "test",
        search_in_name: "false",
        search_in_type: "false",
        search_in_aliases: "false",
        search_in_observations: "false"
      }
      expect(response).to have_http_status(:unprocessable_content)
      data = JSON.parse(response.body)
      expect(data["error"]).to include("search field")
    end

    it "includes observation data in entity responses" do
      get "/api/v1/search/subgraph", params: { q: "XqzAlphaZqx" }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      entity = data["entities"].find { |e| e["entity_id"] == entity_a.id }
      expect(entity["observations"]).to be_an(Array)
      expect(entity["observations"].first["content"]).to eq("Alpha observation")
    end
  end

  describe "POST /api/v1/search/subgraph_by_ids" do
    it "returns entities and inter-relations for given IDs" do
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")

      post "/api/v1/search/subgraph_by_ids", params: { entity_ids: [ entity_a.id, entity_b.id ] }, as: :json
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["entities"].length).to eq(2)
      expect(data["relations"].length).to eq(1)
    end

    it "returns 422 when entity_ids is missing" do
      post "/api/v1/search/subgraph_by_ids", params: {}, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      data = JSON.parse(response.body)
      expect(data["error"]).to include("entity_ids")
    end

    it "returns 422 when entity_ids is empty" do
      post "/api/v1/search/subgraph_by_ids", params: { entity_ids: [] }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      data = JSON.parse(response.body)
      expect(data["error"]).to include("entity_ids")
    end

    it "returns empty arrays when no entities match the IDs" do
      post "/api/v1/search/subgraph_by_ids", params: { entity_ids: [ 999_998, 999_999 ] }, as: :json
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["entities"]).to eq([])
      expect(data["relations"]).to eq([])
    end
  end
end
