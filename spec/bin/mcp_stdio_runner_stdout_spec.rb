# frozen_string_literal: true

require "rails_helper"
require "open3"

# mcp plan PR-2 §2.13: the stdio runner's stdout carries JSON-RPC 2.0 and nothing else.
RSpec.describe "bin/mcp_stdio_runner.rb stdout" do
  # The runner is another process: its writes (tool telemetry, agent context) are committed
  # outside this example's transaction, so clean them up explicitly.
  self.use_transactional_tests = false

  let(:messages) do
    [
      { jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "stdout-spec", version: "0" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" },
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "get_current_time", arguments: {} } }
    ]
  end

  around do |example|
    started_at = Time.current
    example.run
  ensure
    [ ToolInvocation, AgentContext ].each { |model| model.where(created_at: started_at..).delete_all }
  end

  def run_runner(lines = messages.map { |message| JSON.generate(message) }, extra_env: {})
    env = { "RAILS_ENV" => "test", "OLLAMA_URL" => "http://127.0.0.1:9", "GRAPH_MEM_MCP_PROFILE" => "default" }.merge(extra_env)
    Open3.popen3(env, RbConfig.ruby, Rails.root.join("bin/mcp_stdio_runner.rb").to_s, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait|
      lines.each { |line| stdin.puts(line) }
      stdin.close
      err_reader = Thread.new { stderr.read }
      out = Timeout.timeout(90) { stdout.read }
      Timeout.timeout(30) { wait.value }
      [ out, err_reader.value ]
    end
  end

  it "writes only JSON-RPC 2.0 lines to stdout across initialize, tools/list and tools/call" do
    out, err = run_runner
    replies = out.lines.map { |line| JSON.parse(line) }

    expect(replies).to all(include("jsonrpc" => "2.0"))
    expect(replies.map { |reply| reply["id"] }).to eq([ 1, 2, 3 ])
    expect(replies.first.dig("result", "protocolVersion")).to eq("2025-11-25")
    expect(replies.first["result"]).to include(
      "instructions" => GraphMem::McpInstructions.for(:default),
      "capabilities" => GraphMem::McpServerOptions::CAPABILITIES.deep_stringify_keys
    )
    expect(err).to include("Registered tool")
  end

  it "refuses a line over GRAPH_MEM_MCP_MAX_REQUEST_BYTES with -32600 and keeps serving" do
    oversized = JSON.generate(jsonrpc: "2.0", id: 1, method: "ping", params: { pad: "x" * 5_000 })
    out, = run_runner([ oversized, JSON.generate(jsonrpc: "2.0", id: 2, method: "ping") ],
                      extra_env: { "GRAPH_MEM_MCP_MAX_REQUEST_BYTES" => "2000" })
    replies = out.lines.map { |line| JSON.parse(line) }

    expect(replies.first.dig("error", "code")).to eq(-32_600)
    expect(replies.last).to include("id" => 2, "result" => {})
  end
end
