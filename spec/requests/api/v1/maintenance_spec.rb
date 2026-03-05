# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Maintenance", type: :request do
  describe "GET /api/v1/maintenance/stats" do
    it "returns totals, distribution, and computed stats" do
      entity = MemoryEntity.create!(name: "StatsEntity", entity_type: "Project")
      MemoryObservation.create!(memory_entity: entity, content: "Stats obs")

      get "/api/v1/maintenance/stats"
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data["totals"]).to include("entities", "observations", "relations", "audit_logs")
      expect(data["totals"]["entities"]).to be >= 1
      expect(data["totals"]["observations"]).to be >= 1
      expect(data).to have_key("entity_type_distribution")
      expect(data).to have_key("orphan_count")
      expect(data).to have_key("stale_count")
      expect(data).to have_key("most_connected")
      expect(data).to have_key("recently_updated")
    end

    it "returns recently_updated as an array with correct keys" do
      MemoryEntity.create!(name: "RecentEntity", entity_type: "Task")

      get "/api/v1/maintenance/stats"
      data = JSON.parse(response.body)
      recent = data["recently_updated"]
      expect(recent).to be_an(Array)
      return if recent.empty?

      item = recent.first
      expect(item).to include("id", "name", "entity_type", "updated_at")
    end

    it "counts orphan entities correctly" do
      MemoryEntity.create!(name: "OrphanEntity", entity_type: "Orphan")
      connected = MemoryEntity.create!(name: "Connected", entity_type: "Project")
      MemoryObservation.create!(memory_entity: connected, content: "has obs")

      get "/api/v1/maintenance/stats"
      data = JSON.parse(response.body)
      expect(data["orphan_count"]).to be >= 1
    end

    it "reports most_connected entities" do
      a = MemoryEntity.create!(name: "Hub", entity_type: "Project")
      b = MemoryEntity.create!(name: "Spoke1", entity_type: "Task")
      c = MemoryEntity.create!(name: "Spoke2", entity_type: "Task")
      MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of")
      MemoryRelation.create!(from_entity: a, to_entity: c, relation_type: "part_of")

      get "/api/v1/maintenance/stats"
      data = JSON.parse(response.body)
      most = data["most_connected"]
      expect(most).to be_an(Array)
      hub = most.find { |m| m["id"] == a.id }
      expect(hub["relation_count"]).to eq(2) if hub
    end
  end

  describe "GET /api/v1/maintenance/suggest_merges" do
    it "returns suggestions array with threshold_used" do
      get "/api/v1/maintenance/suggest_merges"
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data).to have_key("suggestions")
      expect(data["suggestions"]).to be_an(Array)
      expect(data).to have_key("threshold_used")
    end

    it "accepts threshold and limit params" do
      get "/api/v1/maintenance/suggest_merges", params: { threshold: 0.5, limit: 5 }
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["threshold_used"]).to eq(0.5)
    end

    it "accepts entity_type filter" do
      get "/api/v1/maintenance/suggest_merges", params: { entity_type: "Project" }
      expect(response).to have_http_status(:ok)
    end
  end
end
