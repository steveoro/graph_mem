# frozen_string_literal: true

require "rails_helper"

# MCP Apps step A (1.87.0): the io.modelcontextprotocol/ui extension, the ui://graph-mem/graph
# view on every profile, and what stays as it was. In-process JSON-RPC against the real servers.
RSpec.describe "MCP Apps on the wire" do
  def rpc(server, method, params = nil)
    request = { jsonrpc: "2.0", id: 1, method: method }
    request[:params] = params if params
    JSON.parse(JSON.generate(server.handle(request)))
  end

  def initialize_result(server)
    rpc(server, "initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "SynthClient", version: "0" } })["result"]
  end

  let(:base) { GraphMem::OfficialMcp::ServerFactory::CAPABILITIES.deep_stringify_keys }

  it "declares the extension on initialize and keeps the rest of the capabilities" do
    capabilities = initialize_result(GraphMem::OfficialMcp::ServerFactory.for(:default, apps_enabled: true))["capabilities"]

    expect(capabilities.except("extensions")).to eq(base)
    expect(capabilities["extensions"]).to eq("io.modelcontextprotocol/ui" => { "mimeTypes" => [ "text/html;profile=mcp-app" ] })
  end

  %i[default readonly maintenance].each do |profile|
    it "lists the graph view on the #{profile} profile" do
      resources = rpc(GraphMem::OfficialMcp::ServerFactory.for(profile, apps_enabled: true), "resources/list").dig("result", "resources")

      expect(resources).to eq([ { "uri" => "ui://graph-mem/graph", "name" => "graph_view", "title" => "Graph view",
                                  "description" => GraphMem::McpApps::Views::VIEWS.first[:description],
                                  "mimeType" => "text/html;profile=mcp-app" } ])
    end
  end

  describe "resources/read" do
    let(:server) { GraphMem::OfficialMcp::ServerFactory.for(:readonly, apps_enabled: true) }

    it "serves the view as a full HTML document with _meta.ui on the content item" do
      content = rpc(server, "resources/read", { uri: "ui://graph-mem/graph" }).dig("result", "contents").sole

      expect(content).to include("uri" => "ui://graph-mem/graph", "mimeType" => "text/html;profile=mcp-app",
                                 "_meta" => { "ui" => { "prefersBorder" => true } })
      expect(content["text"]).to start_with("<!doctype html>").and include("</html>")
      expect(content["_meta"]["ui"].keys).to eq([ "prefersBorder" ]) # no csp, permissions or domain
    end

    it "still reads the templated resources and refuses an unknown URI" do
      entity = MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project")

      templated = rpc(server, "resources/read", { uri: "memory_graph?entity_id=#{entity.id}" }).dig("result", "contents").sole
      expect(templated).to include("mimeType" => "application/json")
      expect(templated["text"]).to include("synth-alpha-project")
      expect(rpc(server, "resources/read", { uri: "ui://graph-mem/unknown" })).to include("error")
    end
  end
end
