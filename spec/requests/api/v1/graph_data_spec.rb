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
end
