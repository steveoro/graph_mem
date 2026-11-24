# frozen_string_literal: true

require "rails_helper"
require "open3"

# MCP over stdio on the official SDK: the structured tool output, and the spawned
# bin/mcp_stdio_runner.rb (stdout carries JSON-RPC 2.0 and nothing else, mcp plan PR-2 §2.13).
RSpec.describe "MCP structured output over stdio" do
  describe "the default profile's server" do
    let(:server) { GraphMem::OfficialMcp::ServerFactory.for(:default) }

    def dispatch(request) = JSON.parse(JSON.generate(server.handle(request)))

    it "advertises schemas for the 12 visible default tools" do
      tools = dispatch(jsonrpc: "2.0", method: "tools/list", id: 1).dig("result", "tools")

      expect(tools.size).to eq(12)
      expect(tools).to all(include("outputSchema"))
    end

    it "mirrors structured content as JSON text and keeps metadata separate" do
      result = dispatch(jsonrpc: "2.0", method: "tools/call", params: { name: "get_current_time", arguments: {} }, id: 2).fetch("result")

      expect(JSON.parse(result.dig("content", 0, "text"))).to eq(result["structuredContent"])
      expect(result["structuredContent"]).not_to have_key("_meta")
      expect(result["_meta"]).to include("graphMemVersion" => GraphMem::VERSION)
    end
  end

  describe "the spawned runner" do
    # The runner is another process: its writes (tool telemetry, agent context) are committed
    # outside this example's transaction, so clean them up explicitly.
    self.use_transactional_tests = false

    let(:handshake) do
      [
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "stdout-spec", version: "0" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" }
      ]
    end

    around do |example|
      started_at = Time.current
      example.run
    ensure
      [ ToolInvocation, AgentContext ].each { |model| model.where(created_at: started_at..).delete_all }
    end

    def run_runner(messages, extra_env: {})
      env = { "RAILS_ENV" => "test", "OLLAMA_URL" => "http://127.0.0.1:9", "GRAPH_MEM_MCP_PROFILE" => "default" }.merge(extra_env)
      lines = messages.map { |message| message.is_a?(String) ? message : JSON.generate(message) }
      Open3.popen3(env, RbConfig.ruby, Rails.root.join("bin/mcp_stdio_runner.rb").to_s, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait|
        err_reader = Thread.new { stderr.read }
        stdin.binmode # a raw line may hold invalid UTF-8 bytes on purpose
        lines.each { |line| stdin.puts(line) }
        stdin.close
        out = Timeout.timeout(90) { stdout.read }
        Timeout.timeout(30) { wait.value }
        [ out, err_reader.value ]
      end
    end

    def replies(out) = out.lines.map { |line| JSON.parse(line) }

    it "writes only JSON-RPC 2.0 lines to stdout across initialize, tools/list and tools/call" do
      out, err = run_runner(handshake + [
        { jsonrpc: "2.0", id: 2, method: "tools/list" },
        { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "get_current_time", arguments: {} } }
      ])

      expect(replies(out)).to all(include("jsonrpc" => "2.0"))
      expect(replies(out).map { |reply| reply["id"] }).to eq([ 1, 2, 3 ])
      expect(replies(out).first["result"]).to include(
        "protocolVersion" => "2025-11-25",
        "instructions" => GraphMem::McpInstructions.for(:default),
        "capabilities" => GraphMem::OfficialMcp::ServerFactory.capabilities(apps_enabled: GraphMem::McpApps.enabled?).deep_stringify_keys
      )
      expect(err).to include("serving 12 tools")
    end

    it "returns a failed tool call as the same ToolError JSON envelope as HTTP" do
      out, = run_runner(handshake + [
        { jsonrpc: "2.0", id: 4, method: "tools/call",
          params: { name: "scan_project", arguments: { project_root: "/nonexistent/graph-mem-scan-root", dry_run: true } } }
      ], extra_env: { "GRAPH_MEM_MCP_PROFILE" => "maintenance" })
      reply = replies(out).find { |message| message["id"] == 4 }

      expect(reply.dig("result", "isError")).to be(true)
      expect(JSON.parse(reply.dig("result", "content", 0, "text"))).to include(
        "error" => true, "category" => "validation", "code" => "not_mounted", "tool" => "scan_project", "retriable" => false
      )
    end

    it "deletes an empty Project only when GRAPH_MEM_MCP_PROFILE is maintenance" do
      project = MemoryEntity.create!(name: "Stdio profile project #{SecureRandom.hex(4)}", entity_type: "Project")
      call = lambda do |profile|
        out, = run_runner(handshake + [
          { jsonrpc: "2.0", id: 5, method: "tools/call",
            params: { name: "graph_delete", arguments: { operations: [ { type: "delete_entity", entity_id: project.id } ] } } }
        ], extra_env: { "GRAPH_MEM_MCP_PROFILE" => profile })
        replies(out).find { |message| message["id"] == 5 }["result"]
      end

      expect(JSON.parse(call.call("default").dig("content", 0, "text"))).to include("code" => "project_delete_needs_maintenance")
      expect(MemoryEntity.exists?(project.id)).to be(true)

      expect(call.call("maintenance")["isError"]).not_to be(true)
      expect(MemoryEntity.exists?(project.id)).to be(false)
    ensure
      MemoryEntity.where(id: project&.id).delete_all
      AuditLog.where(auditable_type: "MemoryEntity", auditable_id: project&.id).delete_all
      ChangeSet.where(subject_type: "MemoryEntity", subject_id: project&.id).delete_all # the graph_delete is a change set (UI-4a)
    end

    # mcp 1.9.0 (#651); before it, a string _meta was ignored and the tools were listed.
    it "refuses a tools/list whose _meta is not an object with -32602 and the id" do
      out, = run_runner(handshake + [ { jsonrpc: "2.0", id: 8, method: "tools/list", params: { _meta: "x" } } ])
      reply = replies(out).find { |message| message["id"] == 8 }

      expect(reply).to include("error" => include("code" => -32_602, "message" => "Invalid params: _meta must be an object"))
    end

    # MCP Apps (1.87.0): the view travels over stdio like any resource.
    it "serves the ui://graph-mem/graph view over stdio" do
      out, = run_runner(handshake + [ { jsonrpc: "2.0", id: 11, method: "resources/read", params: { uri: "ui://graph-mem/graph" } } ])
      content = replies(out).find { |message| message["id"] == 11 }.dig("result", "contents").sole

      expect(content).to include("mimeType" => "text/html;profile=mcp-app", "_meta" => { "ui" => { "prefersBorder" => true } })
      expect(content["text"]).to start_with("<!doctype html>")
    end

    # mcp 1.10.0 (#672); before it, -32603 "Internal error" with the id.
    it "refuses a method name that is not valid UTF-8 with -32600 and the id, then still answers a ping" do
      # Built as bytes: JSON.generate would refuse the raw 0xFF in the method name.
      invalid = %({"jsonrpc":"2.0","id":9,"method":"tools/\xFFlist"}).b
      out, = run_runner(handshake + [ invalid, { jsonrpc: "2.0", id: 10, method: "ping" } ])

      expect(replies(out).find { |message| message["id"] == 9 }).to include("error" => include("code" => -32_600))
      expect(replies(out).find { |message| message["id"] == 10 }).to include("result" => {})
    end

    # mcp 1.11.0 (#687); before it, -32603 "Internal error" with the id.
    it "refuses a resources/read without params with -32602 and the id, then still answers a ping" do
      out, = run_runner(handshake + [ { jsonrpc: "2.0", id: 12, method: "resources/read" }, { jsonrpc: "2.0", id: 13, method: "ping" } ])

      expect(replies(out).find { |message| message["id"] == 12 }).to include("error" => include("code" => -32_602, "data" => "Missing or invalid uri"))
      expect(replies(out).find { |message| message["id"] == 13 }).to include("result" => {})
    end

    # mcp 1.11.0 (#688); before it, the ping was answered with the id echoed.
    it "refuses an integer id beyond 128 bits with -32600 and no id, then still answers a ping" do
      oversized = %({"jsonrpc":"2.0","id":340282366920938463463374607431768211456,"method":"ping"}) # 2**128
      out, = run_runner(handshake + [ oversized, { jsonrpc: "2.0", id: 14, method: "ping" } ])

      refused, pong = replies(out).drop(1) # after the initialize reply, in order

      expect(refused).to include("error" => include("code" => -32_600))
      expect(refused).not_to have_key("id")
      expect(pong).to include("id" => 14, "result" => {})
    end

    it "ends the session on a line over GRAPH_MEM_MCP_MAX_REQUEST_BYTES without writing anything else" do
      oversized = JSON.generate(jsonrpc: "2.0", id: 6, method: "ping", params: { pad: "x" * 5_000 })
      out, = run_runner(handshake + [ oversized, { jsonrpc: "2.0", id: 7, method: "ping" } ],
                        extra_env: { "GRAPH_MEM_MCP_MAX_REQUEST_BYTES" => "2000" })

      expect(replies(out).map { |reply| reply["id"] }).to eq([ 1 ])
    end
  end
end
