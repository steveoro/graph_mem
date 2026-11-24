# frozen_string_literal: true

require "rails_helper"

# MCP Apps Search mode (1.89.0): the search summary pages the view reads, recorded from the real
# tool on synthetic data, with a query and each filter kind the view sends. Embeddings are off in
# specs (EmbeddingHelper), so the hits come from the text strategy and no request leaves the process.
RSpec.describe "MCP Apps graph view: the search results Search mode reads" do
  let(:server) { GraphMem::OfficialMcp::ServerFactory.for(:readonly, apps_enabled: true) }
  let!(:alpha) { MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "synth-beta-project", entity_type: "Project") }
  let!(:task) { fs_member!(alpha, "synth-quokka-a", "Task") }
  let!(:issue) { fs_member!(alpha, "synth-quokka-b", "Issue") }
  let!(:aliased) { fs_member!(beta, "synth-gamma", "Task", aliases: "synth-quokka-c") }

  hit_keys = %w[entity_id name entity_type project_id description aliases relevance_score matched_fields]

  def call(arguments)
    reply = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search", arguments: arguments } })
    JSON.parse(JSON.generate(reply)).fetch("result")
  end

  def structured(arguments)
    result = call(arguments)
    expect(result["isError"]).not_to be(true), result.dig("content", 0, "text")
    expect(JSON.parse(result.dig("content", 0, "text"))).to eq(result["structuredContent"]) # the view's fallback
    result.fetch("structuredContent")
  end

  def hit_ids(arguments) = structured({ query: "quokka", **arguments }).fetch("results").map { |hit| hit["entity_id"] }

  it "a query: summary hits with the keys the view shows, and a pager without a total" do
    data = structured({ query: "quokka", page: 1, per_page: 20 })

    expect(data["mode"]).to eq("summary")
    expect(data["results"]).to all(include(*hit_keys))
    expect(data["results"].map { |hit| hit["entity_id"] }).to contain_exactly(task.id, issue.id, aliased.id)
    expect(data["results"].find { |hit| hit["entity_id"] == aliased.id }["matched_fields"]).to eq([ "aliases" ])
    expect(data["pagination"]).to eq("per_page" => 20, "current_page" => 1)
  end

  it "project_id: the project's members only" do
    expect(hit_ids(project_id: alpha.id)).to contain_exactly(task.id, issue.id)
  end

  it "entity_types: those types only" do
    expect(hit_ids(entity_types: [ "Issue" ])).to eq([ issue.id ])
  end

  it "search_in_* false: the field no longer matches" do
    expect(hit_ids(search_in_aliases: false)).to contain_exactly(task.id, issue.id)
    expect(hit_ids(search_in_name: false)).to eq([ aliased.id ])
    expect(hit_ids(search_in_type: false, search_in_observations: false)).to contain_exactly(task.id, issue.id, aliased.id)
  end

  it "perspective: world or experience, with the same hit keys" do
    %w[world experience].each do |perspective|
      expect(structured({ query: "quokka", perspective: perspective })["results"]).to all(include(*hit_keys))
    end
  end

  it "paging: a short last page, which turns the view's Next off" do
    first = structured({ query: "quokka", page: 1, per_page: 2 })
    last = structured({ query: "quokka", page: 2, per_page: 2 })

    expect(first["results"].size).to eq(2)
    expect(last["results"].size).to eq(1)
    expect(last["pagination"]).to eq("per_page" => 2, "current_page" => 2)
  end

  it "a bad filter: a ToolError whose message the view shows in its status line" do
    result = call({ query: "quokka", search_in_name: false, search_in_type: false, search_in_aliases: false, search_in_observations: false })

    expect(result["isError"]).to be(true)
    expect(result).not_to have_key("structuredContent") # the view parses the JSON text (bridge.structured)
    expect(JSON.parse(result.dig("content", 0, "text"))["message"]).to include("At least one search field")
  end
end
