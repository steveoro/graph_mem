# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.17 (per-profile instructions) and §2.18 (capabilities graph_mem delivers).
RSpec.describe "MCP initialize options", type: :request do
  after { AgentContext.delete_all }

  def initialize_result(path)
    host! "localhost"
    post path,
      params: { jsonrpc: "2.0", id: 1, method: "initialize",
                params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "rspec", version: "0" } } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
    expect(response).to have_http_status(:ok)
    [ JSON.parse(response.body)["result"], response.headers["Mcp-Session-Id"] ]
  end

  { "/mcp" => :default, "/mcp/readonly" => :readonly, "/mcp/maintenance" => :maintenance }.each do |path, profile|
    it "sends the #{profile} instructions and only the capabilities graph_mem delivers on #{path}" do
      result, = initialize_result(path)

      expect(result["instructions"]).to eq(GraphMem::McpInstructions.for(profile))
      expect(result["capabilities"]).to eq(GraphMem::McpServerOptions::CAPABILITIES.deep_stringify_keys)
    end
  end

  it "omits instructions when there are none for the profile" do
    allow(GraphMem::McpInstructions).to receive(:for).and_return(nil)

    result, = initialize_result("/mcp")

    expect(result).not_to have_key("instructions")
  end

  it "answers resources/subscribe with -32601, since subscribe isn't advertised" do
    _result, session_id = initialize_result("/mcp")
    post "/mcp",
      params: { jsonrpc: "2.0", id: 2, method: "resources/subscribe", params: { uri: "memory_entities" } }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "Mcp-Session-Id" => session_id }

    expect(JSON.parse(response.body)["error"]).to include("code" => -32_601)
  end
end
