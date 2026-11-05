# frozen_string_literal: true

require "rails_helper"

# mcp 1.9.0 (#650, #651): a request whose `_meta` is not an object (a string, an array, a number) is
# refused with -32602 "Invalid params: _meta must be an object" before any handler runs, on both
# lifecycles; `_meta: null` reads as absent. Next to the #629 block in mcp_official_spec.rb (kept in its
# own file: that one is past 500 lines). Synthetic data only.
RSpec.describe "MCP requests with a non-object _meta", type: :request do
  def request_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }

  before do
    host! "localhost"
    GraphMem::OfficialMcp.reset!
  end

  after do
    GraphMem::OfficialMcp.reset!
    AgentContext.delete_all
  end

  def initialize_session(path)
    post path,
      params: { jsonrpc: "2.0", id: 1, method: "initialize",
                params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "SynthClient", version: "1" } } }.to_json,
      headers: request_headers
    response.headers["Mcp-Session-Id"]
  end

  def rpc(path, session_id, method, params:, id: 2)
    post path, params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json,
               headers: request_headers.merge("Mcp-Session-Id" => session_id)
    response.parsed_body
  end

  # (a) Before 1.9.0 the legacy lifecycle ignored a string `_meta` and listed the tools.
  %w[/mcp /mcp/readonly].each do |path|
    it "refuses a legacy tools/list with _meta \"x\" on #{path}: HTTP 200, -32602, the id echoed" do
      session_id = initialize_session(path)

      body = rpc(path, session_id, "tools/list", params: { _meta: "x" }, id: 21)

      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => 21, "error" => include("code" => -32_602, "message" => "Invalid params: _meta must be an object"))
      expect(body).not_to have_key("result")
    end
  end

  it "reads _meta: null as absent and lists the tools" do
    session_id = initialize_session("/mcp")

    body = rpc("/mcp", session_id, "tools/list", params: { _meta: nil }, id: 22)

    expect(body).to include("id" => 22)
    expect(body.dig("result", "tools").size).to eq(12)
  end

  # (b) Before 1.9.0 a tools/call with an array `_meta` raised TypeError in call_tool (an -32603).
  it "refuses a tools/call with _meta [1] and never runs the tool" do
    session_id = initialize_session("/mcp")
    invocations = ToolInvocation.count
    audits = AuditLog.count

    body = rpc("/mcp", session_id, "tools/call", params: { name: "get_current_time", arguments: {}, _meta: [ 1 ] }, id: 23)

    expect(body).to include("id" => 23, "error" => include("code" => -32_602))
    expect(ToolInvocation.count).to eq(invocations)
    expect(AuditLog.count).to eq(audits)
  end

  # (c) Before 1.9.0 a 2026-07-28 request with a string `_meta` raised TypeError in
  # validate_modern_headers: HTTP 500.
  it "refuses a 2026-07-28 request with _meta \"x\": HTTP 400, -32602" do
    post "/mcp", params: { jsonrpc: "2.0", id: 24, method: "tools/list", params: { _meta: "x" } }.to_json,
                 headers: request_headers.merge("HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => "tools/list")

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to include("id" => 24, "error" => include("code" => -32_602))
    expect(response.headers["Mcp-Session-Id"]).to be_nil
  end
end
