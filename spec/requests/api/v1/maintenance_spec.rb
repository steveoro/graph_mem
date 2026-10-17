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
      MemoryRelation.create!(from_entity: b, to_entity: a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: c, to_entity: a, relation_type: "part_of")

      get "/api/v1/maintenance/stats"
      data = JSON.parse(response.body)
      most = data["most_connected"]
      expect(most).to be_an(Array)
      hub = most.find { |m| m["id"] == a.id }
      expect(hub["relation_count"]).to eq(2) if hub
    end

    describe "god_nodes" do
      def create_hub_with_degree(degree)
        EmbeddingService.suppress_inline_embeddings do
          hub = MemoryEntity.create!(name: "ApiGodHub-#{SecureRandom.hex(4)}", entity_type: "Entity")
          target_rows = degree.times.map do |i|
            { name: "ApiGodTarget-#{hub.id}-#{i}", entity_type: "Entity",
              created_at: Time.current, updated_at: Time.current }
          end
          MemoryEntity.insert_all!(target_rows)
          target_ids = MemoryEntity.where(name: target_rows.map { |row| row[:name] }).pluck(:id)
          MemoryRelation.insert_all!(
            target_ids.map do |to_id|
              { from_entity_id: hub.id, to_entity_id: to_id, relation_type: "calls",
                created_at: Time.current, updated_at: Time.current }
            end
          )
          hub
        end
      end

      it "uses the strict degree > threshold boundary" do
        boundary = create_hub_with_degree(GetGraphStatsTool::GOD_NODE_DEGREE_THRESHOLD)
        over = create_hub_with_degree(GetGraphStatsTool::GOD_NODE_DEGREE_THRESHOLD + 1)

        get "/api/v1/maintenance/stats"
        data = JSON.parse(response.body)
        god_ids = data["god_nodes"].map { |g| g["id"] }

        expect(god_ids).to include(over.id)
        expect(god_ids).not_to include(boundary.id)
        expect(data["god_node_count"]).to eq(1)
      end
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
