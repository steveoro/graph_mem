# frozen_string_literal: true

require "rails_helper"

RSpec.describe MemoryGraphResource, type: :model do
  let!(:a) { MemoryEntity.create!(name: "Graph A", entity_type: "Project") }
  let!(:b) { MemoryEntity.create!(name: "Graph B", entity_type: "Task") }
  let!(:c) { MemoryEntity.create!(name: "Graph C", entity_type: "Task") }

  let!(:r_ab) { MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "part_of") }
  let!(:r_bc) { MemoryRelation.create!(from_entity: b, to_entity: c, relation_type: "depends_on") }

  def content_for(params)
    JSON.parse(described_class.new(params).content)
  end

  it "returns an error when entity_id is missing" do
    expect(content_for({})).to include("error")
  end

  it "returns an error when the entity does not exist" do
    result = content_for(entity_id: "999999")
    expect(result["error"]).to include("Entity not found")
  end

  it "returns the entity with nested relations preserving the response shape" do
    result = content_for(entity_id: a.id.to_s, depth: "2", include_observations: "true", include_relations: "true")

    expect(result["id"]).to eq(a.id)
    expect(result["outgoing_relations"]).to be_an(Array)
    expect(result["incoming_relations"]).to eq([])

    outgoing = result["outgoing_relations"].first
    expect(outgoing["relation_type"]).to eq("part_of")
    expect(outgoing["to_entity"]["id"]).to eq(b.id)
    expect(outgoing["to_entity"]["outgoing_relations"].first["to_entity"]["id"]).to eq(c.id)
  end

  it "omits relations when include_relations is not requested" do
    result = content_for(entity_id: a.id.to_s, depth: "2")
    expect(result).not_to have_key("outgoing_relations")
  end

  it "caps depth at 3" do
    result = content_for(entity_id: a.id.to_s, depth: "99", include_relations: "true")
    expect(result).to have_key("outgoing_relations")
  end
end
