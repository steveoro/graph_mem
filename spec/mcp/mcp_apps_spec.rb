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

  describe "tools/list" do
    def linked(server)
      rpc(server, "tools/list").dig("result", "tools").select { |tool| tool.key?("_meta") }.to_h { |tool| [ tool["name"], tool["_meta"] ] }
    end

    it "links exactly traverse_graph and find_shortest_path to the graph view, nested only (no flat alias)" do
      expect(linked(GraphMem::OfficialMcp::ServerFactory.for(:default, apps_enabled: true)))
        .to eq("traverse_graph" => { "ui" => { "resourceUri" => "ui://graph-mem/graph" } },
               "find_shortest_path" => { "ui" => { "resourceUri" => "ui://graph-mem/graph" } })
    end

    it "never links a tool to a view its server doesn't register, per profile and with the views off" do
      %i[default readonly maintenance].each do |profile|
        [ true, false ].each do |apps_enabled|
          server = GraphMem::OfficialMcp::ServerFactory.for(profile, apps_enabled: apps_enabled)
          listed = rpc(server, "resources/list").dig("result", "resources").map { |resource| resource["uri"] }

          expect(linked(server).values.map { |meta| meta.dig("ui", "resourceUri") }).to all(be_in(listed)), "#{profile} #{apps_enabled}"
          expect(linked(server)).to be_empty unless apps_enabled
        end
      end
    end

    it "leaves a tool unlinked when its view isn't registered on that server" do
      allow(GraphMem::McpApps::Views).to receive(:uris_for).and_return([])

      expect(linked(GraphMem::OfficialMcp::ServerFactory.for(:readonly, apps_enabled: true))).to be_empty
    end
  end

  describe "tools/call" do
    it "answers byte for byte the same whether or not the client declares the extension" do
      start = MemoryEntity.create!(name: "synth-path-start", entity_type: "Component")
      finish = MemoryEntity.create!(name: "synth-path-end", entity_type: "Component")
      MemoryRelation.create!(from_entity: start, to_entity: finish, relation_type: "depends_on")
      apps = { extensions: { "io.modelcontextprotocol/ui" => { mimeTypes: [ "text/html;profile=mcp-app" ] } } }

      results = [ {}, apps ].map do |capabilities|
        server = GraphMem::OfficialMcp::ServerFactory.for(:default, apps_enabled: true)
        rpc(server, "initialize", { protocolVersion: "2025-11-25", capabilities: capabilities, clientInfo: { name: "SynthClient", version: "0" } })
        %w[find_shortest_path traverse_graph].map do |name|
          arguments = name == "find_shortest_path" ? { from_entity_id: start.id, to_entity_id: finish.id } : { start_entity_id: start.id }
          JSON.generate(rpc(server, "tools/call", { name: name, arguments: arguments })["result"])
        end
      end

      expect(results.first).to eq(results.last)
      expect(results.first.first).to include("synth-path-end")
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
