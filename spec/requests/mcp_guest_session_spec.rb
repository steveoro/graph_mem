# frozen_string_literal: true

require "rails_helper"

# /mcp* is Rack middleware with its own access gate (IP allowlist + bearer token) and never
# reads the browser session: a guest (or operator) cookie grants no MCP access (UI-1).
RSpec.describe "MCP ignores browser sessions", type: :request do
  let(:headers) { { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" } }

  before do
    host! "localhost"
    ENV["GRAPH_MEM_MCP_TOKEN"] = "synthetic-token"
    GraphMem::OfficialMcp.reset!
    enable_guest!
    sign_in_guest
    expect(response).to redirect_to(search_path)
  end

  after do
    ENV.delete("GRAPH_MEM_MCP_TOKEN")
    GraphMem::OfficialMcp.reset!
  end

  %w[/mcp /mcp/readonly].each do |path|
    it "answers a guest session without a bearer token with 401 on #{path}, changing nothing" do
      write = { jsonrpc: "2.0", id: 1, method: "tools/call",
                params: { name: "graph_write", arguments: { entities: [ { name: "Intruder", entity_type: "Task" } ] } } }

      expect {
        post path, params: write.to_json, headers: headers
      }.not_to change { [ MemoryEntity.count, AuditLog.count ] }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Bearer realm="graph_mem"')
    end
  end
end
