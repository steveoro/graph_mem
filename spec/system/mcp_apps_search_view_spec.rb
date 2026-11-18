# frozen_string_literal: true

require "rails_helper"

# MCP Apps Search mode (1.89.0) in headless Chrome, through the stub host of
# spec/support/mcp_apps_view_helpers.rb. Search mode is reached from the view's own switch, with
# no tool result (Cursor mounts one view per chat and search isn't linked); its search,
# get_entities and get_context calls are answered by the real readonly tools on synthetic data.
RSpec.describe "MCP Apps graph view: Search mode", :mcp_apps_view, type: :system do
  let(:host_context) { { theme: "dark", displayMode: "inline", availableDisplayModes: %w[inline] } }

  let!(:project) { MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project") }
  # 25 hits for "quokka": three Issues, then Tasks; the first ten in the project.
  let!(:hits) do
    (1..25).map do |i|
      MemoryEntity.create!(name: format("synth-quokka-%02d", i), entity_type: i <= 3 ? "Issue" : "Task",
                           project_id: (project.id if i <= 10))
    end
  end

  before do
    MemoryRelation.create!(from_entity: hits[0], to_entity: hits[1], relation_type: "relates_to")
    MemoryRelation.create!(from_entity: hits[1], to_entity: project, relation_type: "part_of")
    MemoryObservation.create!(memory_entity: hits[0], content: "synth-quokka-01 observation one")
    MemoryObservation.create!(memory_entity: hits[0], content: "synth-quokka-01 observation two")
  end

  def open_search_mode
    open_view
    within_frame("view") do
      expect(page).to have_text("No tool result reached this view")
      find_by_id("mode-search").click
    end
    wait_until { calls_served.any? { |call| call["name"] == "get_context" } || serve_pending.positive? }
  end

  # Answers whatever the view has queued; returns how many calls it answered.
  def serve_pending
    calls = page.evaluate_script("window.hostTakeCalls()")
    calls.each do |call|
      calls_served << call.slice("name", "arguments")
      page.execute_script("window.hostReply(arguments[0], arguments[1])", call["id"], tool_result(call["name"], call["arguments"]))
    end
    calls.size
  end

  def run_query(text)
    within_frame("view") do
      fill_in "search-query", with: text
      find_by_id("search-run").click
    end
  end

  def hit_names = within_frame("view") { all("#search-hits > li > button").map(&:text) }
  def searches = calls_served.select { |call| call["name"] == "search" }

  it "switches to Search mode with no tool result, runs a query and tells the model about it" do
    open_search_mode
    within_frame("view") do
      expect(page).to have_css("#search", visible: true)
      expect(page).to have_no_css("#graph", visible: true)
      expect(find_by_id("mode-search")["aria-pressed"]).to eq("true")
    end
    run_query("quokka")
    serve_view_calls_until("20 hits on page 1.")

    expect(hit_names.size).to eq(20)
    expect(searches.last["arguments"]).to eq("query" => "quokka", "page" => 1, "per_page" => 20)
    wait_until { host_log.any? { |m| m["method"] == "ui/update-model-context" && m.dig("params", "structuredContent", "view") == "search" } }
    update = host_log.reverse.find { |m| m["method"] == "ui/update-model-context" }["params"]
    expect(update["structuredContent"]).to include("view" => "search", "query" => "quokka", "page" => 1, "filters" => {})
    expect(update.dig("content", 0, "text")).to eq('graph_mem search view: "quokka", page 1, 20 hits.')
    expect(console_errors).to be_empty
  end

  it "pages with previous / next, and turns Next off on a short page" do
    open_search_mode
    run_query("quokka")
    serve_view_calls_until("20 hits on page 1.")
    within_frame("view") do
      expect(find_by_id("search-prev")).to be_disabled
      find_by_id("search-next").click
    end
    serve_view_calls_until("5 hits on page 2.")

    within_frame("view") do
      expect(page).to have_text("Page 2")
      expect(find_by_id("search-next")).to be_disabled
      expect(find_by_id("search-prev")).not_to be_disabled
    end
    expect(hit_names.size).to eq(5)
    expect(searches.last["arguments"]).to include("page" => 2)
  end

  it "narrows the hits with the type and project filters, the project being one the view has drawn" do
    open_view
    push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 }))
    within_frame("view") do
      expect(page).to have_text("Traversal from synth-alpha-project")
      find_by_id("mode-search").click
      expect(page).to have_select("search-project", with_options: [ "synth-alpha-project (##{project.id})" ])
      fill_in "Types", with: "Issue"
    end
    run_query("quokka")
    serve_view_calls_until("3 hits on page 1.")
    expect(searches.last["arguments"]).to include("entity_types" => [ "Issue" ])

    within_frame("view") do
      fill_in "Types", with: ""
      select "synth-alpha-project (##{project.id})", from: "search-project"
      uncheck "aliases"
    end
    run_query("quokka")
    serve_view_calls_until("10 hits on page 1.")
    expect(searches.last["arguments"]).to eq("query" => "quokka", "project_id" => project.id, "search_in_aliases" => false, "page" => 1, "per_page" => 20)
    expect(hit_names).to match_array(hits.first(10).map(&:name))
  end

  it "opens a hit's details with one get_entities call, and draws the hits as a graph" do
    open_search_mode
    run_query("quokka")
    serve_view_calls_until("20 hits on page 1.")
    calls_served.clear

    within_frame("view") { find("#search-hits button", text: "synth-quokka-01").click }
    serve_view_calls_until("synth-quokka-01 observation two")
    expect(calls_served).to eq([ { "name" => "get_entities", "arguments" => { "entity_ids" => [ hits[0].id ], "relations" => "all" } } ])
    within_frame("view") { expect(find_by_id("panel-type").text).to eq("Issue") }

    # The two Issues 01 and 02 rank on page 1 (type, then name), with the one relation between hits.
    expect(hit_names).to include("synth-quokka-01", "synth-quokka-02")
    within_frame("view") { find_by_id("search-graph").click }
    serve_view_calls_until("20 hits drawn.")

    within_frame("view") do
      expect(page).to have_css("#graph", visible: true)
      expect(find_by_id("mode-graph")["aria-pressed"]).to eq("true")
      expect(find_by_id("counts").text).to eq("20 entities, 1 relation")
      expect(page).to have_text('Search: "quokka", page 1')
    end
    expect(calls_served.select { |call| call["name"] == "get_entities" }.last["arguments"]).to include("observation_limit" => 1)
    expect(console_errors).to be_empty
  end

  # The project filter's get_context runs outside run(): a result pushed while it is open waits in
  # pendingResult and must be drawn when that call ends (#178 review), not at the next search.
  it "draws a tool result pushed while the project filter's get_context is open" do
    open_view
    within_frame("view") do
      expect(page).to have_text("No tool result reached this view")
      find_by_id("mode-search").click
    end
    wait_until { page.evaluate_script("window.hostQueued()") == 1 } # get_context, not answered yet
    push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 }))
    serve_view_calls_until("Tool result drawn.")

    expect(calls_served.map { |call| call["name"] }).to eq([ "get_context" ])
    within_frame("view") do
      expect(find_by_id("mode-graph")["aria-pressed"]).to eq("true")
      expect(page).to have_text("Traversal from synth-alpha-project")
    end
  end

  it "keeps the drawing while Search mode is shown" do
    open_view
    push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 }))
    within_frame("view") do
      expect(page).to have_text("Traversal from synth-alpha-project")
      counts = find_by_id("counts").text
      find_by_id("mode-search").click
      expect(page).to have_no_css("#graph", visible: true)
      find_by_id("mode-graph").click
      expect(find_by_id("counts").text).to eq(counts)
    end
  end

  it "shows a search error in the status line" do
    open_search_mode
    within_frame("view") { %w[name type aliases observations].each { |field| uncheck field } }
    run_query("quokka")
    serve_view_calls_until("Searching failed")

    within_frame("view") do
      expect(find_by_id("status")[:class]).to include("error")
      expect(find_by_id("status").text).to include("At least one search field")
    end
    expect(console_errors).to be_empty
  end
end
