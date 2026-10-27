# frozen_string_literal: true

require "rails_helper"

# MCP over Streamable HTTP on the official MCP Ruby SDK (docs/guides/migrating-fast-mcp-to-mcp-gem.md):
# profile gating, access control, the tool error envelope, sessions and the success metadata.
# Synthetic data only.
RSpec.describe "MCP on the official SDK", type: :request do
  profile_tool_counts = { "/mcp" => 12, "/mcp/readonly" => 9, "/mcp/maintenance" => 22 }

  def request_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }

  before do
    host! "localhost"
    GraphMem::OfficialMcp.reset!
  end

  after do
    GraphMem::OfficialMcp.reset!
    AgentContext.delete_all
  end

  # Sets ENV for the block and rebuilds the access policy and transports around it.
  def with_env(vars)
    saved = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| ENV[key] = value }
    GraphMem::OfficialMcp.reset!
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    GraphMem::OfficialMcp.reset!
  end

  def initialize_session(path = "/mcp", version: "2025-11-25", headers: {})
    post path,
      params: { jsonrpc: "2.0", id: 1, method: "initialize",
                params: { protocolVersion: version, capabilities: {}, clientInfo: { name: "SynthClient", version: "1" } } }.to_json,
      headers: request_headers.merge(headers)
    response.headers["Mcp-Session-Id"]
  end

  def rpc(path, session_id, method, params: nil, id: 2, headers: {})
    payload = { jsonrpc: "2.0", id: id, method: method }
    payload[:params] = params if params
    post path, params: payload.to_json, headers: request_headers.merge("Mcp-Session-Id" => session_id).merge(headers)
    response.parsed_body
  end

  def tool_call(path, session_id, name, arguments = {}, headers: {})
    rpc(path, session_id, "tools/call", params: { name: name, arguments: arguments }, headers: headers)
  end

  def envelope(body)
    expect(body.dig("result", "isError")).to be(true)
    JSON.parse(body.dig("result", "content", 0, "text"))
  end

  describe "initialize" do
    { "/mcp" => :default, "/mcp/readonly" => :readonly, "/mcp/maintenance" => :maintenance }.each do |path, profile|
      it "sends the #{profile} instructions and only the capabilities graph_mem delivers on #{path}" do
        expect(initialize_session(path)).to be_present
        result = response.parsed_body["result"]

        expect(result["protocolVersion"]).to eq("2025-11-25")
        expect(result["instructions"]).to eq(GraphMem::McpInstructions.for(profile))
        expect(result["capabilities"]).to eq(GraphMem::OfficialMcp::ServerFactory::CAPABILITIES.deep_stringify_keys)
        expect(result["serverInfo"]).to include("name" => "graph-mem", "version" => GraphMem::VERSION)
      end
    end

    it "echoes an older supported version and answers 2025-11-25 to an unsupported one" do
      initialize_session("/mcp", version: "2024-11-05")
      expect(response.parsed_body.dig("result", "protocolVersion")).to eq("2024-11-05")

      initialize_session("/mcp", version: "1999-01-01")
      expect(response.parsed_body.dig("result", "protocolVersion")).to eq("2025-11-25")
    end
  end

  describe "profile gating" do
    profile_tool_counts.each do |path, count|
      it "lists #{count} tools on #{path}" do
        session_id = initialize_session(path)
        names = rpc(path, session_id, "tools/list").dig("result", "tools").map { |tool| tool["name"] }

        profile = GraphMem::OfficialMcp::Router.profile_for(path)
        expect(names).to match_array(GraphMem::McpToolRegistry.tool_classes_for(profile).map(&:tool_name))
        expect(names.size).to eq(count)
      end
    end

    it "advertises every tool's annotations" do
      session_id = initialize_session("/mcp/maintenance")
      tools = rpc("/mcp/maintenance", session_id, "tools/list").dig("result", "tools").index_by { |tool| tool["name"] }

      expect(tools.values).to all(include("annotations" => include("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")))
      expect(tools.dig("summarize", "annotations")).to include("readOnlyHint" => true, "openWorldHint" => true)
      expect(tools.dig("graph_delete", "annotations")).to include("destructiveHint" => true, "idempotentHint" => false)
    end

    it "refuses a write tool on /mcp/readonly and writes nothing" do
      session_id = initialize_session("/mcp/readonly")

      expect {
        body = tool_call("/mcp/readonly", session_id, "graph_write",
                         { operations: [ { type: "create_entity", name: "SynthWidget Readonly", entity_type: "Task" } ] })
        expect(body.dig("error", "code")).to eq(-32_602)
      }.not_to change(MemoryEntity, :count)
    end

    it "refuses a maintenance tool on /mcp and serves it on /mcp/maintenance" do
      session_id = initialize_session("/mcp")
      expect(tool_call("/mcp", session_id, "dream_state_status").dig("error", "code")).to eq(-32_602)

      session_id = initialize_session("/mcp/maintenance")
      body = tool_call("/mcp/maintenance", session_id, "dream_state_status")
      expect(body.dig("result", "isError")).not_to be(true)
    end

    it "deletes an empty Project through graph_delete only on the maintenance profile" do
      project = MemoryEntity.create!(name: "SynthProject #{SecureRandom.hex(3)}", entity_type: "Project")
      delete_project = { operations: [ { type: "delete_entity", entity_id: project.id } ] }

      session_id = initialize_session("/mcp")
      expect(envelope(tool_call("/mcp", session_id, "graph_delete", delete_project))).to include("code" => "project_delete_needs_maintenance")
      expect(MemoryEntity.exists?(project.id)).to be(true)

      session_id = initialize_session("/mcp/maintenance")
      expect(tool_call("/mcp/maintenance", session_id, "graph_delete", delete_project).dig("result", "isError")).not_to be(true)
      expect(MemoryEntity.exists?(project.id)).to be(false)
    end

    it "lists no persist prompt on /mcp/readonly and refuses to render it there" do
      session_id = initialize_session("/mcp/readonly")
      expect(rpc("/mcp/readonly", session_id, "prompts/list").dig("result", "prompts").pluck("name")).to contain_exactly("orient", "recall")
      expect(rpc("/mcp/readonly", session_id, "prompts/get", params: { name: "persist", arguments: {} }).dig("error", "code")).to eq(-32_602)
    end

    it "lists and renders the workflow prompts on /mcp" do
      session_id = initialize_session("/mcp")
      prompts = rpc("/mcp", session_id, "prompts/list").dig("result", "prompts")
      expect(prompts.pluck("name")).to contain_exactly("orient", "recall", "persist")
      expect(prompts.find { |prompt| prompt["name"] == "recall" }["arguments"]).to include(
        "name" => "topic", "description" => "Keywords or subject to recall", "required" => true
      )

      text = rpc("/mcp", session_id, "prompts/get", params: { name: "recall", arguments: { topic: "SynthWidget" } }).dig("result", "messages", 0, "content", "text")
      expect(text).to include("SynthWidget", "search", "get_entities")
    end

    it "lists the four resource templates and reads one" do
      entity = MemoryEntity.create!(name: "SynthWidget Resource", entity_type: "Component")
      session_id = initialize_session("/mcp")

      templates = rpc("/mcp", session_id, "resources/templates/list").dig("result", "resourceTemplates")
      expect(templates.pluck("name")).to contain_exactly("MemoryEntities", "MemoryGraph", "MemoryObservations", "MemoryRelations")

      contents = rpc("/mcp", session_id, "resources/read", params: { uri: "memory_graph?entity_id=#{entity.id}" }).dig("result", "contents")
      expect(contents.first).to include("uri" => "memory_graph?entity_id=#{entity.id}", "mimeType" => "application/json")
      expect(JSON.parse(contents.first["text"])).to include("name" => "SynthWidget Resource")
    end
  end

  describe "access control" do
    it "answers a missing or wrong bearer token with 401 and WWW-Authenticate, and serves the right one" do
      with_env("GRAPH_MEM_MCP_TOKEN" => "synthetic-token") do
        initialize_session("/mcp")
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq('Bearer realm="graph_mem"')

        initialize_session("/mcp", headers: { "HTTP_AUTHORIZATION" => "Bearer wrong-token" })
        expect(response).to have_http_status(:unauthorized)

        expect(initialize_session("/mcp", headers: { "HTTP_AUTHORIZATION" => "Bearer synthetic-token" })).to be_present
      end
    end

    it "answers an IP outside GRAPH_MEM_MCP_ALLOWED_IPS with 403" do
      with_env("GRAPH_MEM_MCP_ALLOWED_IPS" => "10.9.9.9") do
        initialize_session("/mcp")
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "answers a foreign Host or Origin with 403, and accepts a host listed in GRAPH_MEM_MCP_ALLOWED_HOSTS" do
      host! "rebinding.example"
      initialize_session("/mcp")
      expect(response).to have_http_status(:forbidden)

      host! "localhost"
      initialize_session("/mcp", headers: { "HTTP_ORIGIN" => "http://rebinding.example" })
      expect(response).to have_http_status(:forbidden)

      with_env("GRAPH_MEM_MCP_ALLOWED_HOSTS" => "graphmem.lan") do
        host! "graphmem.lan"
        expect(initialize_session("/mcp")).to be_present
      end
    end

    it "accepts an Origin listed in GRAPH_MEM_MCP_ALLOWED_ORIGINS" do
      with_env("GRAPH_MEM_MCP_ALLOWED_ORIGINS" => "http://synth-ui.localhost:3001") do
        expect(initialize_session("/mcp", headers: { "HTTP_ORIGIN" => "http://synth-ui.localhost:3001" })).to be_present
      end
    end

    it "records the X-MCP-Client on the tool_invocations row, and the default client without one" do
      session_id = initialize_session("/mcp")
      tool_call("/mcp", session_id, "get_current_time", {}, headers: { "X-MCP-Client" => "synth-client" })
      tool_call("/mcp", session_id, "get_current_time")

      expect(ToolInvocation.where(tool_name: "get_current_time").pluck(:client_id)).to include("synth-client", GraphMemContext::DEFAULT_CLIENT_ID)
      expect(AgentContext.find_by(client_id: "synth-client")).to be_present
    end
  end

  describe "tool error envelope" do
    it "answers invalid arguments with the validation envelope" do
      session_id = initialize_session("/mcp")
      payload = envelope(tool_call("/mcp", session_id, "graph_write", { operations: [ { type: "bogus" } ] }))

      expect(payload).to include("error" => true, "category" => "validation", "retriable" => false, "tool" => "graph_write")
    end

    it "answers a scan_project refusal with its code" do
      session_id = initialize_session("/mcp/maintenance")
      payload = envelope(tool_call("/mcp/maintenance", session_id, "scan_project", { project_root: "/nonexistent/synth-root", dry_run: true }))

      expect(payload).to include("category" => "validation", "code" => "not_mounted", "tool" => "scan_project")
    end

    it "answers an ambiguous name in a graph_write batch with ambiguous_name and the candidates" do
      name = "SynthMember #{SecureRandom.hex(3)}"
      2.times do |n|
        project = MemoryEntity.create!(name: "SynthProject #{n} #{SecureRandom.hex(3)}", entity_type: "Project")
        MemoryEntity.create!(name: name, entity_type: "Task", project_id: project.id)
      end
      session_id = initialize_session("/mcp")
      payload = envelope(tool_call("/mcp", session_id, "graph_write", { operations: [ { type: "create_observation", entity_name: name, text_content: "synthetic" } ] }))

      expect(payload).to include("category" => "ambiguous_name", "tool" => "graph_write")
      expect(payload["message"]).to start_with("create_observation[0]: Name '#{name}' is ambiguous")
    end

    it "answers an unknown id with the not_found envelope and no backtrace" do
      session_id = initialize_session("/mcp/maintenance")
      body = tool_call("/mcp/maintenance", session_id, "scan_project_status", { scan_id: "synthetic-unknown-scan" })

      expect(body.dig("result", "content", 0, "text")).not_to include("app/tools")
      expect(envelope(body)).to include("error" => true, "category" => "not_found", "retriable" => false, "tool" => "scan_project_status")
    end
  end

  describe "success metadata" do
    it "adds the version, next_move, context banner and _meta" do
      session_id = initialize_session("/mcp")
      result = tool_call("/mcp", session_id, "get_current_time")["result"]

      expect(JSON.parse(result.dig("content", 0, "text"))).to eq(result["structuredContent"])
      expect(result["structuredContent"]).to include(
        "version" => GraphMem::VERSION, "next_move" => include("timestamp"), "context" => include("status" => "none")
      )
      expect(result["_meta"]).to eq("graphMemVersion" => GraphMem::VERSION, "contextStatus" => "none")
    end
  end

  describe "sessions" do
    it "ends a session on DELETE" do
      session_id = initialize_session("/mcp")
      delete "/mcp", headers: { "Mcp-Session-Id" => session_id }
      expect(response).to have_http_status(:ok)

      rpc("/mcp", session_id, "tools/list")
      expect(response).to have_http_status(:not_found)
    end

    it "answers a new initialize with 503 once GRAPH_MEM_MCP_MAX_SESSIONS sessions are open" do
      with_env("GRAPH_MEM_MCP_MAX_SESSIONS" => "2") do
        2.times { expect(initialize_session("/mcp")).to be_present }

        initialize_session("/mcp")
        expect(response).to have_http_status(:service_unavailable)
      end
    end
  end

  # mcp 1.8.2 (#629): a reply that can't be generated as JSON gets -32603 with the request id, not HTTP 500.
  # The gem echoes the tool name in "Tool not found", so an invalid UTF-8 byte in it is a one-request trigger.
  describe "a reply that can't be encoded as JSON" do
    # Built as bytes: to_json would refuse the raw 0xFF in the tool name.
    let(:body) { %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"synth-\xFF","arguments":{}}}).b }

    %w[/mcp /mcp/readonly].each do |path|
      it "answers -32603 with the id on #{path} and reports the JSON::GeneratorError" do
        allow(Rails.error).to receive(:report).and_call_original
        session_id = initialize_session(path)

        post path, params: body, headers: request_headers.merge("Mcp-Session-Id" => session_id)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("id" => 7, "error" => include("code" => -32_603))
        expect(Rails.error).to have_received(:report).with(an_instance_of(JSON::GeneratorError), any_args).at_least(:once)
      end
    end
  end

  describe "CORS preflight (rack-cors)" do
    %w[/mcp /mcp/readonly /mcp/maintenance].each do |path|
      it "answers a preflight on #{path}" do
        options path, headers: { "HTTP_ORIGIN" => "http://localhost:3001", "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
                                 "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "content-type,mcp-session-id,x-mcp-client" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["access-control-allow-methods"]).to include("POST")
        expect(response.headers["access-control-expose-headers"]).to include("Mcp-Session-Id")
      end
    end
  end
end
