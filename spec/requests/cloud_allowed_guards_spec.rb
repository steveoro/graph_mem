# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step U: cloud_allowed is set only on the Projects page. MCP, REST, Explore and
# the JSON import engine (graphify:import, rails_ast:import) ignore a cloud_allowed key; an export never carries it.
RSpec.describe "cloud_allowed guards", type: :request do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }

  it "MCP graph_edit and graph_write ignore it" do
    GraphEditTool.new.call(operations: [ { type: "update_entity", entity_id: project.id, description: "Synthetic.", cloud_allowed: true } ])
    GraphWriteTool.new.call(operations: [ { type: "create_entity", name: "Alpha Project", entity_type: "Project", cloud_allowed: true } ])

    expect(project.reload).to have_attributes(description: "Synthetic.", cloud_allowed: false)
    expect(MemoryEntity.find_by!(name: "Alpha Project").cloud_allowed).to be(false)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "the REST create and update ignore it" do
      patch "/api/v1/memory_entities/#{project.id}", params: { memory_entity: { description: "Synthetic.", cloud_allowed: true } }, as: :json
      post "/api/v1/memory_entities", params: { memory_entity: { name: "Alpha Project", entity_type: "Project", cloud_allowed: true } }, as: :json

      expect(project.reload).to have_attributes(description: "Synthetic.", cloud_allowed: false)
      expect(MemoryEntity.find_by!(name: "Alpha Project").cloud_allowed).to be(false)
    end

    it "the Explore edit form ignores it" do
      patch explore_entity_path(project), params: { entity: { description: "Synthetic.", cloud_allowed: "1" } }, headers: ExploreWriteHelpers::STREAM

      expect(project.reload).to have_attributes(description: "Synthetic.", cloud_allowed: false)
    end
  end

  it "the JSON import engine ignores it" do
    root = { "name" => "Alpha Project", "entity_type" => "Project", "aliases" => "", "cloud_allowed" => true, "observations" => [], "children" => [] }
    report = ImportExecutionStrategy.new.execute({ "version" => "1.0", "root_nodes" => [ root ] }, [ { node_path: "0", action: "create" } ])

    expect(report.success).to be(true)
    expect(MemoryEntity.find_by!(name: "Alpha Project").cloud_allowed).to be(false)
  end

  it "an export never carries it" do
    project.update!(cloud_allowed: true)

    expect(sql_export(project)).not_to include("cloud_allowed")
  end
end
