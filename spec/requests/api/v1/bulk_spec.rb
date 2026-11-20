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

      it "creates observations with structured metadata" do
        params = {
          observations: [
            {
              entity_id: entity.id,
              text_content: "Metadata observation",
              confidence: 0.8,
              source: "bulk-api",
              tags: [ "request" ]
            }
          ]
        }

        post "/api/v1/bulk", params: params, as: :json

        data = JSON.parse(response.body)
        observation = MemoryObservation.find(data["created_observations"].first["observation_id"])
        expect(observation).to have_attributes(confidence: 0.8, source: "bulk-api", tags: [ "request" ])
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

      it "creates relations with metadata and canonicalized types" do
        RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")
        params = {
          relations: [
            {
              from_entity_id: ent_a.id,
              to_entity_id: ent_b.id,
              relation_type: "requires",
              weight: 2.0,
              confidence: 0.9,
              properties: { source: "bulk-api" }
            }
          ]
        }

        post "/api/v1/bulk", params: params, as: :json

        data = JSON.parse(response.body)
        relation = MemoryRelation.find(data["created_relations"].first["relation_id"])
        expect(relation).to have_attributes(relation_type: "depends_on", weight: 2.0, confidence: 0.9)
        expect(relation.properties).to eq("source" => "bulk-api")
      end
    end

    context "creating part_of relations (membership)" do
      let!(:alpha) { MemoryEntity.create!(name: "Alpha Project", entity_type: "Project") }
      let!(:beta) { MemoryEntity.create!(name: "Beta Project", entity_type: "Project") }
      let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
      let!(:gear) { MemoryEntity.create!(name: "SynthGear", entity_type: "Component") }

      it "syncs each child's project, for part_of and for a Part Of spelling" do
        params = { relations: [ { from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "part_of" },
                                { from_entity_id: gear.id, to_entity_id: beta.id, relation_type: "Part Of" } ] }

        post "/api/v1/bulk", params: params, as: :json

        expect(response).to have_http_status(:created)
        expect(JSON.parse(response.body)["created_relations"].map { |rel| rel["relation_type"] }).to eq(%w[part_of part_of])
        expect([ widget.reload.project_id, gear.reload.project_id ]).to eq([ alpha.id, beta.id ])
      end

      it "refuses a second parent and rolls the whole call back" do
        MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
        ProjectMembership.sync!(widget)
        params = { relations: [ { from_entity_id: gear.id, to_entity_id: beta.id, relation_type: "part_of" },
                                { from_entity_id: widget.id, to_entity_id: beta.id, relation_type: "child_of" } ] }

        post "/api/v1/bulk", params: params, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Bulk operation rolled back")
        expect(body["details"].sole).to include("type" => "relation", "index" => 1)
        expect(body["details"].sole["error"]).to include("already has a part_of parent")
        expect(MemoryRelation.where(from_entity_id: gear.id)).to be_empty
        expect([ widget.reload.project_id, gear.reload.project_id ]).to eq([ alpha.id, nil ])
      end

      it "refuses a name collision in the target project" do
        MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id)

        post "/api/v1/bulk", params: { relations: [ { from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "part_of" } ] },
                             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["details"].sole["error"]).to include("already exists there")
        expect(MemoryRelation.where(from_entity_id: widget.id)).to be_empty
        expect(widget.reload.project_id).to be_nil
      end

      it "answers 422 and writes nothing when the membership lock is busy" do
        allow(ProjectMembership).to receive(:with_membership_lock).and_raise(ProjectMembership::LockTimeout, "lock busy")

        post "/api/v1/bulk", params: { entities: [ { name: "SynthGadget", entity_type: "Component" } ],
                                       relations: [ { from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "part_of" } ] },
                             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["details"].sole["error"]).to eq("lock busy; retry shortly")
        expect(MemoryEntity.exists?(name: "SynthGadget")).to be(false)
      end

      it "doesn't take the membership lock for a batch without a part_of" do
        allow(ProjectMembership).to receive(:with_membership_lock).and_call_original

        post "/api/v1/bulk", params: { relations: [ { from_entity_id: widget.id, to_entity_id: gear.id, relation_type: "depends_on" } ] },
                             as: :json

        expect(response).to have_http_status(:created)
        expect(ProjectMembership).not_to have_received(:with_membership_lock)
        expect(widget.reload.project_id).to be_nil
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
