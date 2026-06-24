# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Memory Relations duplicate handling", type: :request do
  let!(:entity_from) { MemoryEntity.create!(name: "Dup From", entity_type: "Project") }
  let!(:entity_to) { MemoryEntity.create!(name: "Dup To", entity_type: "Task") }

  describe "POST /api/v1/memory_relations" do
    it "returns the existing relation instead of creating a duplicate" do
      existing = MemoryRelation.create!(
        from_entity: entity_from,
        to_entity: entity_to,
        relation_type: "part_of"
      )

      expect {
        post "/api/v1/memory_relations",
             params: {
               memory_relation: {
                 from_entity_id: entity_from.id,
                 to_entity_id: entity_to.id,
                 relation_type: "part_of"
               }
             },
             as: :json
      }.not_to change(MemoryRelation, :count)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["id"]).to eq(existing.id)
    end
  end

  describe "PATCH /api/v1/memory_relations/:id" do
    let!(:existing) do
      MemoryRelation.create!(
        from_entity: entity_from,
        to_entity: entity_to,
        relation_type: "part_of"
      )
    end

    let!(:other) do
      MemoryRelation.create!(
        from_entity: entity_from,
        to_entity: entity_to,
        relation_type: "depends_on"
      )
    end

    it "returns 422 when updating to a colliding relation type" do
      patch "/api/v1/memory_relations/#{other.id}",
            params: { memory_relation: { relation_type: "part_of" } },
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      data = JSON.parse(response.body)
      expect(data["error"]).to include("Relation already exists")
      expect(other.reload.relation_type).to eq("depends_on")
    end
  end
end
