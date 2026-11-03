# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step M: cloud_allowed on Project roots only, default false, never in REST JSON.
RSpec.describe MemoryEntity, "cloud_allowed" do
  let(:project) { described_class.create!(name: "Gadget Project", entity_type: "Project") }

  it "defaults to false" do
    expect(project.cloud_allowed).to be(false)
    expect(described_class.create!(name: "Alpha Service", entity_type: "Service").cloud_allowed).to be(false)
  end

  it "can be true on a Project root only" do
    expect(project.update(cloud_allowed: true)).to be(true)

    member = described_class.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id)
    global = described_class.create!(name: "Alpha Service", entity_type: "Service")
    [ member, global ].each do |entity|
      expect(entity.update(cloud_allowed: true)).to be(false)
      expect(entity.errors[:cloud_allowed]).to eq([ "can only be set on a Project root" ])
    end
  end

  it "drops the flag when a project stops being a Project root, so the retype still saves" do
    project.update!(cloud_allowed: true, cloud_root: "/path/to/gadget")
    project.update!(entity_type: "Component")

    expect(project.reload).to have_attributes(cloud_allowed: false, cloud_root: nil)
    expect(MemoryEntity.new(name: "Alpha Service", entity_type: "Service", cloud_root: "/path/to/x")).not_to be_valid
  end

  it "keeps the REST JSON as it was: no cloud_allowed (and no embedding) key" do
    project.update!(cloud_allowed: true)

    expect(project.as_json.keys).to match_array(described_class.column_names - %w[embedding cloud_allowed cloud_root])
    expect(project.to_json).not_to include("cloud_allowed", "cloud_root")
  end

  it "can't move with a merge: Project roots are never merged" do
    project.update!(cloud_allowed: true)
    other = described_class.create!(name: "Gadget Archive", entity_type: "Project")

    result = NodeOperationsStrategy.new.merge_into(project.id, other.id)

    expect(result).to include(success: false)
    expect(other.reload.cloud_allowed).to be(false)
    expect(project.reload.cloud_allowed).to be(true)
  end
end

RSpec.describe "REST memory entity JSON without cloud_allowed", type: :request do
  before { sign_in_operator }

  it "show has no cloud_allowed key; create and update return the same keys as before the column" do
    project = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    project.update!(cloud_allowed: true)
    expected = MemoryEntity.column_names - %w[embedding cloud_allowed cloud_root]

    get "/api/v1/memory_entities/#{project.id}", headers: { "Accept" => "application/json" }
    expect(response.parsed_body).to include("id" => project.id)
    expect(response.body).not_to include("cloud_allowed", "cloud_root")

    post "/api/v1/memory_entities", params: { memory_entity: { name: "SynthWidget", entity_type: "Component" } }, as: :json
    expect(response.parsed_body.keys).to match_array(expected)

    patch "/api/v1/memory_entities/#{project.id}", params: { memory_entity: { description: "Synthetic gadgets." } }, as: :json
    expect(response.parsed_body.keys).to match_array(expected)
  end
end
