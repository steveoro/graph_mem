# frozen_string_literal: true

require "rails_helper"

# Tool titles (mcp-sdk-1.9.0 plan, step T): every tool advertises a short human-readable `title` in
# tools/list on every profile. Prompts and resources keep their fields. A client that negotiates
# 2025-03-26 or older still gets a working tools/list (the gem sends the extra field; such a client
# ignores it, as it already does `annotations`). Synthetic data only.
RSpec.describe "MCP tool titles", type: :request do
  profiles = { default: 12, readonly: 9, maintenance: 22 }

  def request_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }

  def listed(profile, method)
    server = GraphMem::OfficialMcp::ServerFactory.for(profile)
    JSON.parse(JSON.generate(server.handle({ jsonrpc: "2.0", id: 1, method: method })))["result"]
  end

  profiles.each do |profile, count|
    it "gives each of the #{count} #{profile} tools a short title, and nothing else one" do
      tools = listed(profile, "tools/list")["tools"]

      expect(tools.size).to eq(count)
      tools.each do |tool|
        expect(tool["title"]).to be_a(String).and(satisfy { |title| title.strip.present? && title.length <= 40 && !title.end_with?(".") })
        expect(tool["title"]).to eq(GraphMem::McpToolRegistry.tool_classes_for(profile).find { |klass| klass.tool_name == tool["name"] }.title)
        expect(tool["annotations"]).not_to have_key("title")
      end
      expect(tools.map { |tool| tool["title"] }.uniq.size).to eq(count)
      expect(listed(profile, "prompts/list")["prompts"]).to all(satisfy { |prompt| !prompt.key?("title") })
    end
  end

  it "titles every registered tool class within the limit" do
    GraphMem::McpToolRegistry.load_all!
    GraphMem::McpToolRegistry.tool_classes.each do |klass|
      expect(klass.title.to_s.length).to be_between(1, ApplicationTool::MAX_TITLE_LENGTH), klass.name
    end
  end

  it "refuses a blank, too long or period-ended title at class load" do
    tool = Class.new(ApplicationTool)

    [ " ", "x" * 41, "Search Graph." ].each { |bad| expect { tool.title(bad) }.to raise_error(ArgumentError) }
    expect(tool.title("x" * 40)).to eq("x" * 40)
  end

  %w[2025-03-26 2024-11-05].each do |version|
    it "still serves tools/list to a #{version} client on /mcp" do
      host! "localhost"
      GraphMem::OfficialMcp.reset!
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize",
                             params: { protocolVersion: version, capabilities: {}, clientInfo: { name: "SynthClient", version: "1" } } }.to_json,
                   headers: request_headers
      session_id = response.headers["Mcp-Session-Id"]
      expect(response.parsed_body.dig("result", "protocolVersion")).to eq(version)

      post "/mcp", params: { jsonrpc: "2.0", id: 2, method: "tools/list" }.to_json,
                   headers: request_headers.merge("Mcp-Session-Id" => session_id, "MCP-Protocol-Version" => version)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("result", "tools").size).to eq(12)
    ensure
      GraphMem::OfficialMcp.reset!
      AgentContext.delete_all
    end
  end
end
