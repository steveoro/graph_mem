# frozen_string_literal: true

require "rails_helper"

# MCP Apps Graph mode (1.88.0) in headless Chrome. No route serves the view: the spec writes a
# stub-host page to a temp file and loads the built document into a sandboxed iframe under the
# host's default CSP. The stub host plays the postMessage protocol: it answers ui/initialize,
# pushes tool results recorded from the real tools on synthetic data, and proxies the view's own
# tools/call requests to the readonly MCP server (the spec polls them and posts the replies).
RSpec.describe "MCP Apps graph view", type: :system do
  # The host default when a resource declares no csp (MCP Apps 2026-01-26, plus the draft's object-src).
  HOST_CSP = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " \
             "img-src 'self' data:; media-src 'self' data:; connect-src 'none'; object-src 'none'"

  let(:host_context) do
    { theme: "light", displayMode: "inline", availableDisplayModes: %w[inline fullscreen],
      styles: { variables: { "--color-background-primary" => "light-dark(#ffffff, #101010)" } } }
  end

  let!(:project) { MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project") }
  let!(:members) do
    %w[Task Issue Component].each_with_index.map do |type, i|
      MemoryEntity.create!(name: "synth-alpha-#{i}", entity_type: type, project_id: project.id).tap do |member|
        MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")
      end
    end
  end
  let!(:root_b) { MemoryEntity.create!(name: "synth-root-b", entity_type: "Project") }
  let!(:loose) { MemoryEntity.create!(name: "synth-loose", entity_type: "Task") }

  before do
    MemoryRelation.create!(from_entity: members[0], to_entity: members[1], relation_type: "relates_to")
    MemoryRelation.create!(from_entity: members[2], to_entity: root_b, relation_type: "depends_on")
    MemoryObservation.create!(memory_entity: members[0], content: "synth-alpha-0 observation one")
    MemoryObservation.create!(memory_entity: members[0], content: "synth-alpha-0 observation two")
  end

  def tool_result(name, arguments) = tool_result_on(:readonly, name, arguments)

  def tool_result_on(profile, name, arguments)
    reply = GraphMem::OfficialMcp::ServerFactory.for(profile, apps_enabled: true).handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
    JSON.parse(JSON.generate(reply)).fetch("result")
  end

  def open_view
    html = GraphMem::McpApps::Views.provider_for(:readonly).read(GraphMem::McpApps::Views::GRAPH_URI).sole[:text]
    html = html.sub("<head>", %(<head>\n<meta http-equiv="Content-Security-Policy" content="#{HOST_CSP}">))
    dir = Dir.mktmpdir("mcp-apps-view")
    temp_dirs << dir
    File.write(File.join(dir, "host.html"), host_page(html))
    visit "file://#{dir}/host.html"
    wait_until { page.evaluate_script("window.viewInitialized === true") }
  end

  def temp_dirs = (@temp_dirs ||= [])

  after { temp_dirs.each { |dir| FileUtils.remove_entry(dir) } }

  def wait_until(timeout: 10)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  end

  # "N entities, M relations" for a recorded result: its entities, and its relations between them.
  def drawn_counts(result)
    data = result.fetch("structuredContent")
    ids = data.fetch("entities").map { |entity| entity["entity_id"] }
    edges = data.fetch("relations", []).count { |relation| ids.include?(relation["from_entity_id"]) && ids.include?(relation["to_entity_id"]) }
    "#{ids.size} #{ids.size == 1 ? 'entity' : 'entities'}, #{edges} #{edges == 1 ? 'relation' : 'relations'}"
  end

  def host_page(view_html)
    <<~HTML
      <!doctype html><html><head><meta charset="utf-8"></head><body>
      <iframe id="view" sandbox="allow-scripts" style="width:1000px;height:700px"></iframe>
      <iframe id="other" sandbox="allow-scripts" style="display:none"></iframe>
      <script>
        const frame = document.getElementById("view");
        const log = [];
        const queue = [];
        const send = (message) => frame.contentWindow.postMessage({ jsonrpc: "2.0", ...message }, "*");
        window.addEventListener("message", (event) => {
          if (event.source !== frame.contentWindow) return;
          const m = event.data;
          log.push(m);
          if (m.method === "ui/initialize") send({ id: m.id, result: { protocolVersion: "2026-01-26", hostInfo: { name: "stub-host", version: "0" }, hostCapabilities: {}, hostContext: #{host_context.to_json} } });
          if (m.method === "ui/notifications/initialized") window.viewInitialized = true;
          if (m.method === "tools/call") queue.push({ id: m.id, name: m.params.name, arguments: m.params.arguments });
          if (m.method === "ui/request-display-mode") send({ id: m.id, result: { mode: m.params.mode } });
          if (m.method === "ui/update-model-context") send({ id: m.id, result: {} });
        });
        window.hostTakeCalls = () => queue.splice(0);
        window.hostQueued = () => queue.length;
        window.hostReply = (id, result) => send({ id, result });
        window.hostSend = (message) => send(message);
        window.hostLog = () => JSON.stringify(log);
        // A sibling frame relays messages to the view: their event.source is not the view's parent.
        document.getElementById("other").srcdoc = '<script>addEventListener("message", (e) => parent.frames[0].postMessage(e.data, "*"));<\\/script>';
        window.otherSend = (message) => document.getElementById("other").contentWindow.postMessage({ jsonrpc: "2.0", ...message }, "*");
        frame.srcdoc = #{view_html.to_json};
      </script></body></html>
    HTML
  end

  # Answers the view's tools/call requests with the real tools until the view shows `text`.
  def serve_view_calls_until(text, timeout: 20)
    deadline = Time.current + timeout
    loop do
      page.evaluate_script("window.hostTakeCalls()").each do |call|
        calls_served << call.slice("name", "arguments")
        page.execute_script("window.hostReply(arguments[0], arguments[1])", call["id"], tool_result(call["name"], call["arguments"]))
      end
      return if within_frame("view") { page.has_text?(text, wait: 0) }
      raise "the view never showed #{text.inspect}; it shows: #{within_frame('view') { page.text }}" if Time.current > deadline

      sleep 0.05
    end
  end

  def calls_served = (@calls_served ||= [])

  def push_tool_result(result)
    page.execute_script("window.hostSend(arguments[0])", { method: "ui/notifications/tool-result", params: result })
  end

  def host_log = JSON.parse(page.evaluate_script("window.hostLog()"))

  def view_counts = within_frame("view") { find_by_id("counts").text }

  def console_errors = page.driver.browser.logs.get(:browser).map(&:message).grep_v(/favicon/)

  # Clicks a node where Cytoscape drew it, once the layout has settled. The spec reads the
  # positions through Cytoscape's own registry on the container; the view exposes nothing.
  def click_node(entity)
    within_frame("view") do
      positions = "JSON.stringify(document.getElementById('graph')._cyreg.cy.nodes().map((n) => n.renderedPosition()))"
      previous = nil
      wait_until { current = page.evaluate_script(positions); settled = current == previous; previous = current; sleep 0.2; settled }
      at = page.evaluate_script("document.getElementById('graph')._cyreg.cy.getElementById('#{entity.id}').renderedPosition()")
      graph = find_by_id("graph")
      size = graph.evaluate_script("[this.clientWidth, this.clientHeight]")
      offset = Capybara.w3c_click_offset ? { x: (at["x"] - (size[0] / 2.0)).round, y: (at["y"] - (size[1] / 2.0)).round } : { x: at["x"].round, y: at["y"].round }
      graph.click(**offset)
    end
  end

  it "draws a traverse_graph expansion with the focus entity and tells the model what it shows" do
    open_view
    result = tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 })
    push_tool_result(result)

    expect(drawn_counts(result)).to start_with("4 entities")
    within_frame("view") do
      expect(page).to have_text("Traversal from synth-alpha-project, depth 1")
      expect(page).to have_text(drawn_counts(result))
      border = ->(entity) { page.evaluate_script("document.getElementById('graph')._cyreg.cy.getElementById('#{entity.id}').style('border-color')") }
      expect(border.call(project)).to eq("rgb(255,255,0)") # GRAPH_STYLES' focus rule
      expect(border.call(members[0])).not_to eq("rgb(255,255,0)")
    end
    wait_until { host_log.any? { |m| m["method"] == "ui/update-model-context" } }
    update = host_log.find { |m| m["method"] == "ui/update-model-context" }["params"]
    expect(update["structuredContent"]).to include("view" => "graph", "entity_count" => 4)
    expect(update.dig("content", 0, "text")).to include("Traversal from synth-alpha-project", "4 entities and")
    expect(console_errors).to be_empty
  end

  it "loads the endpoints of a relations-only result with batched get_entities" do
    open_view
    push_tool_result(tool_result("traverse_graph", { from_entity_id: members[0].id }))
    serve_view_calls_until("3 entities, 2 relations")

    expect(calls_served).to all(include("name" => "get_entities"))
    expect(calls_served.first["arguments"]).to include("relations" => "all", "observation_limit" => 1)
    within_frame("view") { expect(page).to have_text("Relation query") }
    expect(console_errors).to be_empty
  end

  # With no edges the force layout packs the lone nodes in overlapping rows: a grid sized to the
  # labels keeps every label readable.
  it "draws the nodes alone when include leaves out the relations, without overlapping them" do
    24.times do |i|
      member = MemoryEntity.create!(name: "synth-alpha-member-with-a-long-label-#{i}", entity_type: "Task", project_id: project.id)
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "part_of")
    end
    open_view
    push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1, include: %w[entities traversal] }))

    within_frame("view") do
      expect(page).to have_text("28 entities, 0 relations")
      expect(find_by_id("status").text).to eq("Tool result drawn.")
      boxes = "JSON.stringify(document.getElementById('graph')._cyreg.cy.nodes().map((n) => n.boundingBox({ includeLabels: true })))"
      previous = nil
      wait_until { current = page.evaluate_script(boxes); settled = current == previous; previous = current; sleep 0.2; settled }
      overlapping = JSON.parse(previous).combination(2).count do |a, b|
        a["x1"] < b["x2"] && b["x1"] < a["x2"] && a["y1"] < b["y2"] && b["y1"] < a["y2"]
      end
      expect(overlapping).to eq(0)
    end
  end

  it "draws a shortest path, and says when there is none" do
    open_view
    path = tool_result("find_shortest_path", { from_entity_id: members[0].id, to_entity_id: root_b.id, max_depth: 5 })
    push_tool_result(path)
    within_frame("view") do
      expect(page).to have_text("Shortest path, 3 hops")
      expect(page).to have_text(drawn_counts(path))
    end

    push_tool_result(tool_result("find_shortest_path", { from_entity_id: members[0].id, to_entity_id: loose.id }))
    within_frame("view") do
      expect(page).to have_text("No path between the two entities")
      expect(find_by_id("status").text).to eq("No path between the two entities within the search depth.")
    end
    expect(console_errors).to be_empty
  end

  describe "interaction" do
    before do
      open_view
      push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 }))
      within_frame("view") { expect(page).to have_text("Tool result drawn.") }
    end

    it "shows a clicked node's full observations and relations in the panel, with one get_entities call" do
      click_node(members[0])
      serve_view_calls_until("synth-alpha-0 observation two")

      within_frame("view") do
        within("#panel") do
          expect(page).to have_text("synth-alpha-0 (##{members[0].id})")
          expect(page).to have_text("synth-alpha-0 observation one")
          expect(page).to have_text("→ part_of synth-alpha-project (##{project.id})")
        end
        expect(page).to have_text("Selected: synth-alpha-0")
      end
      expect(calls_served).to eq([ { "name" => "get_entities", "arguments" => { "entity_ids" => [ members[0].id ], "relations" => "all" } } ])
      wait_until { host_log.select { |m| m["method"] == "ui/update-model-context" }.last&.dig("params", "structuredContent", "selected_entity_ids") == [ members[0].id ] }
      expect(console_errors).to be_empty
    end

    it "expands a node, then draws the path between two selected nodes" do
      click_node(members[2])
      serve_view_calls_until("synth-alpha-2 (#")
      within_frame("view") { click_button "Expand 1" }
      serve_view_calls_until("Expanded synth-alpha-2 by 1: 1 new entity.")
      within_frame("view") { expect(find_by_id("counts").text).to eq("5 entities, 4 relations") }
      expect(calls_served.find { |call| call["name"] == "traverse_graph" }["arguments"])
        .to eq("start_entity_id" => members[2].id, "max_depth" => 1, "include" => %w[relations traversal])

      click_node(members[0])
      serve_view_calls_until("Selected: synth-alpha-2, synth-alpha-0")
      within_frame("view") { click_button "Path between selected" }
      serve_view_calls_until("Path: 2 hops between synth-alpha-2 and synth-alpha-0.")
      expect(console_errors).to be_empty
    end

    it "shows a project as view state, without changing the agent's context" do
      click_node(project)
      serve_view_calls_until("synth-alpha-project (#")
      within_frame("view") { click_button "Show this project" }
      serve_view_calls_until("Project synth-alpha-project loaded.")

      within_frame("view") { expect(page).to have_text("Project: synth-alpha-project") }
      expect(calls_served.map { |call| call["name"] }.uniq).to match_array(%w[get_entities traverse_graph])
      expect(tool_result("get_context", {}).dig("structuredContent", "status")).to eq("no_context")
    end
  end

  it "caps a relations-only result at 2,000 entities and says what it left out" do
    now = Time.current
    hub = MemoryEntity.create!(name: "synth-hub", entity_type: "Component")
    MemoryEntity.insert_all((1..2_100).map { |i| { name: "synth-leaf-#{i}", entity_type: "Task", created_at: now, updated_at: now } })
    leaves = MemoryEntity.where("name LIKE 'synth-leaf-%'").pluck(:id)
    MemoryRelation.insert_all(leaves.map { |id| { from_entity_id: hub.id, to_entity_id: id, relation_type: "relates_to", created_at: now, updated_at: now } })
    open_view
    push_tool_result(tool_result("traverse_graph", { from_entity_id: hub.id }))
    serve_view_calls_until("Tool result drawn.", timeout: 120)

    within_frame("view") do
      expect(find_by_id("counts").text).to eq("2,000 entities, 1,999 relations")
      expect(page).to have_text("Showing 1,999 of 2,100 relations.")
    end
    expect(calls_served.size).to eq(20)
    expect(calls_served.map { |call| call.dig("arguments", "entity_ids").size }).to all(be <= 100)
    expect(console_errors).to be_empty
  end

  describe "with no tool result (a host that mounts one view per chat)" do
    it "offers the two subset loads and draws the root entities from the paged catalog" do
      MemoryEntity.create!(name: "synth-untyped-root", entity_type: "Task").update_column(:entity_type, nil)
      open_view
      within_frame("view") do
        expect(page).to have_text("No tool result reached this view")
        click_button "Root entities", match: :first
      end
      serve_view_calls_until("Root entities loaded.")

      within_frame("view") { expect(find_by_id("counts").text).to eq("3 entities, 0 relations") }
      expect(calls_served.first).to eq("name" => "search", "arguments" => { "page" => 1, "per_page" => 100 })
      expect(calls_served.last).to include("name" => "get_entities")
      expect(calls_served.last["arguments"]["entity_ids"]).to contain_exactly(project.id, root_b.id, MemoryEntity.find_by!(name: "synth-untyped-root").id)
      expect(console_errors).to be_empty
    end

    it "draws the context project's part_of subtree, or says there is no active project" do
      open_view
      within_frame("view") { click_button "Context project", match: :first }
      serve_view_calls_until("No active project.")

      tool_result_on(:default, "set_context", { entity_id: project.id })
      within_frame("view") { click_button "Context project", match: :first }
      serve_view_calls_until("Context project: synth-alpha-project loaded.")

      within_frame("view") { expect(find_by_id("counts").text).to eq("4 entities, 4 relations") }
      walk = calls_served.find { |call| call["name"] == "traverse_graph" }
      expect(walk["arguments"]).to include("start_entity_id" => project.id, "direction" => "incoming", "relation_types" => [ "part_of" ],
                                           "max_depth" => 5, "max_entities" => 1000)
      expect(console_errors).to be_empty
    end

    it "keeps a tool result pushed during a subset load and draws it when the load ends" do
      open_view
      within_frame("view") { click_button "Root entities", match: :first }
      wait_until { page.evaluate_script("window.hostQueued()") == 1 } # the first catalog page, unanswered
      push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 }))
      serve_view_calls_until("Tool result drawn.")

      within_frame("view") { expect(page).to have_text("Traversal from synth-alpha-project, depth 1") }
    end

    it "waits for the result after a tool-input, and offers the subset loads after a cancellation" do
      open_view
      page.execute_script("window.hostSend(arguments[0])", { method: "ui/notifications/tool-input", params: { arguments: { start_entity_id: project.id } } })
      sleep 2 # past the view's 1.5 s wait for a result
      within_frame("view") do
        expect(page).to have_text("Waiting for the tool result…")
        expect(page).to have_no_text("No tool result reached this view")
      end

      page.execute_script("window.hostSend(arguments[0])", { method: "ui/notifications/tool-cancelled", params: { reason: "synth cancel" } })
      within_frame("view") do
        expect(page).to have_text("The tool call was cancelled.")
        expect(page).to have_button("Root entities", count: 2)
      end
    end

    it "offers the subset loads after a tool result with nothing to draw" do
      open_view
      push_tool_result(tool_result("traverse_graph", { start_entity_id: project.id, include: [ "traversal" ] }))
      within_frame("view") do
        expect(page).to have_text("The tool result holds nothing to draw.")
        expect(find_by_id("status").text).to eq("The tool result holds nothing to draw.")
        expect(page).to have_button("Root entities", count: 2)
      end
    end
  end

  it "ignores a message from another source and an unknown notification, and answers an unknown request with -32601" do
    open_view
    fake = tool_result("traverse_graph", { start_entity_id: project.id, max_depth: 1 })
    page.execute_script("window.otherSend(arguments[0])", { method: "ui/notifications/tool-result", params: fake })
    page.execute_script("window.hostSend(arguments[0])", { method: "ui/notifications/synth-unknown", params: {} })
    page.execute_script("window.hostSend(arguments[0])", { id: 555, method: "ui/synth-future-request", params: {} })

    wait_until { host_log.any? { |m| m["id"] == 555 } }
    expect(host_log.find { |m| m["id"] == 555 }).to include("error" => { "code" => -32_601, "message" => "Method not found" })
    within_frame("view") do
      expect(page).to have_text("No tool result reached this view")
      expect(find_by_id("counts", visible: :all).text(:all)).to eq("")
    end
    expect(console_errors).to be_empty
  end
end
