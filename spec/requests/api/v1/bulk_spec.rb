# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Bulk", type: :request do
  describe "POST /api/v1/bulk" do
    context "creating entities" do
      it "creates entities and returns 201" do
        params = {
          entities: [
            { name: "BulkEnt1", entity_type: "Project" },
            { name: "BulkEnt2", entity_type: "Task" }
          ]
        }
        post "/api/v1/bulk", params: params, as: :json
        expect(response).to have_http_status(:created)
        data = JSON.parse(response.body)
        expect(data["created_entities"].length).to eq(2)
        expect(data["summary"]["entities_created"]).to eq(2)
      end

      it "creates entities with inline observations" do
        params = {
          entities: [
            { name: "WithObs", entity_type: "Project", observations: [ "obs1", "obs2" ] }
          ]
        }
        post "/api/v1/bulk", params: params, as: :json
        expect(response).to have_http_status(:created)

        entity = MemoryEntity.find_by(name: "WithObs")
        expect(entity.memory_observations.count).to eq(2)
      end
    end

    context "creating observations" do
      let!(:entity) { MemoryEntity.create!(name: "BulkObsParent", entity_type: "Project") }

      it "creates observations on existing entities" do
        params = {
          observations: [
            { entity_id: entity.id, text_content: "New obs 1" },
            { entity_id: entity.id, text_content: "New obs 2" }
          ]
        }
        post "/api/v1/bulk", params: params, as: :json
        expect(response).to have_http_status(:created)
        data = JSON.parse(response.body)
        expect(data["created_observations"].length).to eq(2)
      end
    end

    context "creating relations" do
      let!(:ent_a) { MemoryEntity.create!(name: "BulkRelA", entity_type: "Project") }
      let!(:ent_b) { MemoryEntity.create!(name: "BulkRelB", entity_type: "Task") }

      it "creates relations between entities" do
        params = {
          relations: [
            { from_entity_id: ent_a.id, to_entity_id: ent_b.id, relation_type: "part_of" }
          ]
        }
        post "/api/v1/bulk", params: params, as: :json
        expect(response).to have_http_status(:created)
        data = JSON.parse(response.body)
        expect(data["created_relations"].length).to eq(1)
      end
    end

    context "mixed operations" do
      it "creates entities, observations, and relations in a single call" do
        parent = MemoryEntity.create!(name: "MixedParent", entity_type: "Project")
        params = {
          entities: [ { name: "MixedChild", entity_type: "Task" } ],
          observations: [ { entity_id: parent.id, text_content: "Mixed obs" } ],
          relations: []
        }
        post "/api/v1/bulk", params: params, as: :json
        expect(response).to have_http_status(:created)
        data = JSON.parse(response.body)
        expect(data["summary"]["entities_created"]).to eq(1)
        expect(data["summary"]["observations_created"]).to eq(1)
      end
    end

    context "validation errors" do
      it "returns 422 when no operations are provided" do
        post "/api/v1/bulk", params: {}, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        data = JSON.parse(response.body)
        expect(data["error"]).to include("At least one operation")
      end

      it "returns 422 when exceeding MAX_OPERATIONS" do
        entities = 51.times.map { |i| { name: "Ent#{i}", entity_type: "Task" } }
        post "/api/v1/bulk", params: { entities: entities }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        data = JSON.parse(response.body)
        expect(data["error"]).to include("Maximum")
      end

      it "rolls back all operations when an entity fails validation" do
        params = {
          entities: [
            { name: "ValidEntity", entity_type: "Project" },
            { name: nil, entity_type: nil }
          ]
        }
        expect {
          post "/api/v1/bulk", params: params, as: :json
        }.not_to change(MemoryEntity, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
