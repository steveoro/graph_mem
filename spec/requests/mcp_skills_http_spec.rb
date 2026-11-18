# frozen_string_literal: true

require "rails_helper"

# Skills over MCP (1.91.0) over Streamable HTTP: with mcp_skills_enabled on, a session lists and
# reads skills on each profile, and the AccessGate refuses skills/list from outside the allowlist
# like any other method. Synthetic client names only.
RSpec.describe "Skills over MCP over HTTP", type: :request do
  def request_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }

  before do
    host! "localhost"
    AppSettings.mcp_skills_enabled = true
    AppSettings.clear_cache
    GraphMem::OfficialMcp.reset!
  end

  after do
    AppSettings.where(var: "mcp_skills_enabled").delete_all
    GraphMem::OfficialMcp.reset!
    AgentContext.delete_all
  end

  def post_rpc(path, method, params: nil, session: nil, headers: {})
    payload = { jsonrpc: "2.0", id: 1, method: method }
    payload[:params] = params if params
    headers = headers.merge("Mcp-Session-Id" => session) if session
    post path, params: payload.to_json, headers: request_headers.merge(headers)
  end

  def open_session(path, headers: {})
    post_rpc(path, "initialize", headers: headers,
                                 params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "SynthClient", version: "1" } })
    response.headers["Mcp-Session-Id"]
  end

  { "/mcp" => 2, "/mcp/readonly" => 1, "/mcp/maintenance" => 2 }.each do |path, count|
    it "#{path}: declares the extension, lists #{count} skill(s) and reads a SKILL.md" do
      session = open_session(path)
      expect(response.parsed_body.dig("result", "capabilities", "extensions")).to have_key("io.modelcontextprotocol/skills")

      post_rpc(path, "skills/list", session: session)
      expect(response.parsed_body.dig("result", "skills").size).to eq(count)
      post_rpc(path, "resources/read", session: session, params: { uri: "skill://graph-mem-mcp-toolset/SKILL.md" })
      expect(response.parsed_body.dig("result", "contents", 0, "text")).to start_with("---\nname: graph-mem-mcp-toolset\n")
    end
  end

  it "refuses skills/list from an IP outside GRAPH_MEM_MCP_ALLOWED_IPS, as any method" do
    saved = ENV.fetch("GRAPH_MEM_MCP_ALLOWED_IPS", nil)
    ENV["GRAPH_MEM_MCP_ALLOWED_IPS"] = "10.9.9.9"
    GraphMem::OfficialMcp.reset!

    post_rpc("/mcp", "skills/list")
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("skill://")
  ensure
    saved.nil? ? ENV.delete("GRAPH_MEM_MCP_ALLOWED_IPS") : ENV["GRAPH_MEM_MCP_ALLOWED_IPS"] = saved
    GraphMem::OfficialMcp.reset!
  end
end
