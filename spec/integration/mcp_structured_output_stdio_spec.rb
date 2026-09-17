# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe "MCP structured output over stdio" do
  let(:server) { FastMcp::Server.new(name: "graph-mem-test", version: GraphMem::VERSION) }
  let(:transport) { FastMcp::Transports::StdioTransport.new(server) }

  before do
    GraphMem::McpToolRegistry.register_with!(server, profile: :default)
    server.transport = transport
  end

  def dispatch(request)
    output = StringIO.new
    previous_stdout = $stdout
    $stdout = output
    server.handle_request(JSON.generate(request))
    JSON.parse(output.string.lines.last)
  ensure
    $stdout = previous_stdout
  end

  it "advertises schemas for the 12 visible default tools" do
    response = dispatch(jsonrpc: "2.0", method: "tools/list", id: 1)
    tools = response.dig("result", "tools")

    expect(tools.size).to eq(12)
    expect(tools).to all(include("outputSchema"))
  end

  it "mirrors structured content as JSON text and keeps metadata separate" do
    response = dispatch(
      jsonrpc: "2.0",
      method: "tools/call",
      params: { name: "get_current_time", arguments: {} },
      id: 2
    )
    result = response.fetch("result")

    expect(JSON.parse(result.dig("content", 0, "text"))).to eq(result["structuredContent"])
    expect(result["structuredContent"]).not_to have_key("_meta")
    expect(result["_meta"]).to include("graphMemVersion" => GraphMem::VERSION)
  end
end
