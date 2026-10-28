# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Graph Data", type: :request do
  describe "GET /api/v1/graph_data" do
    it "counts active observations only" do
      entity = MemoryEntity.create!(name: "Lifecycle graph node", entity_type: "Project")
      MemoryObservation.create!(memory_entity: entity, content: "Current")
      MemoryObservation.create!(memory_entity: entity, content: "Historical").mark_obsolete!

      get "/api/v1/graph_data"

      expect(response).to have_http_status(:ok)
      node = JSON.parse(response.body)["elements"].find do |element|
        element["group"] == "nodes" && element.dig("data", "id") == entity.id.to_s
      end
      expect(node.dig("data", "memory_observations_count")).to eq(1)
    end
  end

  # UI-3 P6: "Show as graph" from Search.
  describe "GET /api/v1/graph_data?ids=" do
    let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
    let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
    let!(:outside) { MemoryEntity.create!(name: "Outside Node", entity_type: "Component") }
    let!(:inside) { MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on") }

    before { MemoryRelation.create!(from_entity: widget, to_entity: outside, relation_type: "depends_on") }

    def elements(group) = response.parsed_body["elements"].select { |element| element["group"] == group }

    it "returns those entities and the relations among them only, skipping unknown ids" do
      get "/api/v1/graph_data", params: { ids: "#{router.id}, #{widget.id},#{widget.id},999999999" }

      expect(response).to have_http_status(:ok)
      expect(elements("nodes").map { |node| node.dig("data", "id") }).to eq([ widget.id.to_s, router.id.to_s ])
      expect(elements("edges").map { |edge| edge.dig("data", "relation_id") }).to eq([ inside.id ])
      expect(response.parsed_body["options"]).to eq("focus_entity_ids" => [ widget.id.to_s, router.id.to_s ])
    end

    it "accepts 100 ids" do
      get "/api/v1/graph_data", params: { ids: (1..100).to_a.join(",") }

      expect(response).to have_http_status(:ok)
    end

    [ "", "0", "-1", "1,,2", "abc", "1.5", (1..101).to_a.join(",") ].each do |ids|
      it "answers 422 for ids=#{ids.truncate(20).inspect}" do
        get "/api/v1/graph_data", params: { ids: ids }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "ids must be 1 to 100 comma-separated entity ids.")
      end
    end

    it "serves a guest" do
      enable_guest!
      sign_in_guest

      get "/api/v1/graph_data", params: { ids: widget.id.to_s }, headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(elements("nodes").size).to eq(1)
    end
  end
end
