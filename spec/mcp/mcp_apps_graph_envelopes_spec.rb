# frozen_string_literal: true

require "rails_helper"

# MCP Apps Graph mode (1.88.0): the keys the view reads from each tool result, recorded from the
# real tools on synthetic data. The view (lib/graph_mem/mcp_apps/view/) has no JS test runner, so
# a tool-output change that would break it fails here; the system spec drives the view itself.
RSpec.describe "MCP Apps graph view: the tool results it reads" do
  let(:server) { GraphMem::OfficialMcp::ServerFactory.for(:readonly, apps_enabled: true) }
  let!(:project) { MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project") }
  let!(:member) { MemoryEntity.create!(name: "synth-alpha-member", entity_type: "Task", project_id: project.id) }
  let!(:loose) { MemoryEntity.create!(name: "synth-loose", entity_type: "Task") }

  before do
    MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")
    MemoryObservation.create!(memory_entity: member, content: "synth-alpha-member observation")
  end

  def structured(name, arguments)
    reply = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
    result = JSON.parse(JSON.generate(reply)).fetch("result")
    expect(result["isError"]).not_to be(true), result.dig("content", 0, "text")
    expect(JSON.parse(result.dig("content", 0, "text"))).to eq(result["structuredContent"]) # the view's fallback
    result.fetch("structuredContent")
  end

  entity_keys = %w[entity_id name entity_type]
  relation_keys = %w[relation_id from_entity_id to_entity_id relation_type]

  describe "traverse_graph" do
    it "expansion: entities, relations and traversal" do
      data = structured("traverse_graph", { start_entity_id: project.id, max_depth: 1 })

      expect(data["entities"]).to all(include(*entity_keys, "project_id", "aliases"))
      expect(data["relations"]).to all(include(*relation_keys))
      expect(data["traversal"]).to include("start_entity_id" => project.id, "max_depth" => 1, "truncated" => false)
    end

    it "relation query: relations only, with ids and no names" do
      data = structured("traverse_graph", { from_entity_id: member.id })

      expect(data.keys & %w[entities relations traversal]).to eq([ "relations" ])
      expect(data["relations"].sole).to include(*relation_keys)
    end

    it "include: [\"traversal\"]: nothing to draw" do
      expect(structured("traverse_graph", { start_entity_id: project.id, include: [ "traversal" ] }).keys & %w[entities relations]).to be_empty
    end

    it "the project walk: incoming part_of edges and the truncation flag, no entities" do
      data = structured("traverse_graph", { start_entity_id: project.id, direction: "incoming", relation_types: [ "part_of" ],
                                            max_depth: 5, max_entities: 1000, include: %w[relations traversal] })

      expect(data.keys & %w[entities relations traversal]).to eq(%w[relations traversal])
      expect(data["relations"].sole).to include("from_entity_id" => member.id, "to_entity_id" => project.id)
    end
  end

  it "find_shortest_path: found with entities and relations, or found false" do
    expect(structured("find_shortest_path", { from_entity_id: member.id, to_entity_id: project.id }))
      .to include("found" => true, "hop_count" => 1, "entities" => all(include(*entity_keys)), "relations" => all(include(*relation_keys)))
    expect(structured("find_shortest_path", { from_entity_id: member.id, to_entity_id: loose.id })).to include("found" => false)
  end

  it "get_entities: a batch with observation_limit 1 and all relations; one node with every observation" do
    MemoryObservation.create!(memory_entity: member, content: "synth-alpha-member second observation")
    batch = structured("get_entities", { entity_ids: [ member.id, project.id ], relations: "all", observation_limit: 1 })
    expect(batch["entities"]).to all(include(*entity_keys, "observations"))
    expect(batch["entities"].find { |entity| entity["entity_id"] == member.id }["observations"].size).to eq(1)
    expect(batch["relations"]).to all(include(*relation_keys))

    node = structured("get_entities", { entity_ids: [ member.id ], relations: "all" })
    expect(node["entities"].sole["observations"].map { |observation| observation["content"] }).to all(be_a(String)).and(have_attributes(size: 2))
  end

  it "get_context: the active project and its entity count" do
    expect(structured("get_context", {})).to include("status" => "no_context")

    GraphMem::OfficialMcp::ServerFactory.for(:default).handle(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "set_context", arguments: { entity_id: project.id } } }
    )
    expect(structured("get_context", {})).to include("status" => "context_active", "entity_id" => project.id,
                                                     "entity_name" => "synth-alpha-project", "scope_entity_count" => 2)
  end

  it "search with page and per_page only: a catalog page with totals" do
    data = structured("search", { page: 1, per_page: 100 })

    expect(data).to include("mode" => "catalog", "pagination" => include("total_entities" => 3, "total_pages" => 1))
    expect(data["entities"]).to all(include(*entity_keys))
  end
end
