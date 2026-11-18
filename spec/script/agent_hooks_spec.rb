# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "socket"
require "tmpdir"

# Auto-adoption A4 (1.90.0): the SessionStart reminder hooks, run with `sh` against a stub server on
# loopback that answers /up with a chosen status. The scripts print a static reminder only on a 2xx
# answer, and are silent with exit 0 otherwise (refused, an error status, or nothing listening).
RSpec.describe "script/agent_hooks" do
  hooks = File.expand_path("../../script/agent_hooks", __dir__)
  claude = File.join(hooks, "graph_mem_session_start.sh")
  cursor = File.join(hooks, "graph_mem_session_start_cursor.sh")

  # Answers every request with `status` and records the request lines; returns the base URL.
  def stub_server(status)
    server = TCPServer.new("127.0.0.1", 0)
    @requests = []
    @thread = Thread.new do
      loop do
        client = server.accept
        @requests << client.gets.to_s.split[0, 2].join(" ")
        nil while (line = client.gets) && line != "\r\n" # the headers
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        client.close
      end
    end
    @server = server
    "http://127.0.0.1:#{server.addr[1]}"
  end

  # A loopback URL nothing listens on.
  def closed_url
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    "http://127.0.0.1:#{port}"
  end

  after do
    @thread&.kill
    @server&.close
  end

  def run_hook(script, env = {})
    Open3.capture3(env, "sh", script, stdin_data: '{"hook_event_name":"SessionStart","source":"startup"}')
  end

  it "Claude Code: prints the plain-text reminder when /up answers 200" do
    out, err, status = run_hook(claude, "GRAPH_MEM_URL" => stub_server(200))

    expect(status.exitstatus).to eq(0)
    expect(err).to be_empty
    expect(@requests).to eq([ "GET /up" ])
    expect(out).to start_with('graph_mem (MCP server "graph_mem") is connected')
    expect(out).to include("get_context", "search", "graph_write", "use ToolSearch to load the tools")
    expect(out.lines.size).to eq(1)
  end

  it "Cursor: prints one JSON object with additional_context when /up answers 200" do
    out, _err, status = run_hook(cursor, "GRAPH_MEM_URL" => stub_server(200))

    expect(status.exitstatus).to eq(0)
    expect(JSON.parse(out).keys).to eq([ "additional_context" ])
    expect(JSON.parse(out)["additional_context"]).to include("get_context", "read the graph_mem MCP tool descriptions")
  end

  it "keeps the two reminders the same apart from how to load the tools" do
    url = stub_server(200)
    plain = run_hook(claude, "GRAPH_MEM_URL" => url).first.strip
    json = JSON.parse(run_hook(cursor, "GRAPH_MEM_URL" => url).first)["additional_context"]

    expect(json.sub("read the graph_mem MCP tool descriptions", "use ToolSearch to load the tools")).to eq(plain)
  end

  it "is silent with exit 0 when the server is down or answers an error" do
    [ closed_url, stub_server(500), stub_server(401) ].each do |url|
      [ claude, cursor ].each do |script|
        out, err, status = run_hook(script, "GRAPH_MEM_URL" => url)

        expect([ out, err, status.exitstatus ]).to eq([ "", "", 0 ]), "#{File.basename(script)} on #{url}"
      end
    end
  end

  it "touches GRAPH_MEM_HOOK_MARKER each run, up or down, and writes nothing else" do
    Dir.mktmpdir("agent-hooks") do |dir|
      marker = File.join(dir, "synth-hook-fired")
      [ claude, cursor ].each do |script|
        File.delete(marker) if File.exist?(marker)
        run_hook(script, "GRAPH_MEM_URL" => closed_url, "GRAPH_MEM_HOOK_MARKER" => marker)

        expect(Dir.children(dir)).to eq([ "synth-hook-fired" ]), File.basename(script)
      end
    end
  end

  it "is POSIX sh with only static text: no graph data, paths or hostnames beyond the loopback default" do
    [ claude, cursor ].each do |script|
      text = File.read(script)

      expect(text.lines.first).to eq("#!/usr/bin/env sh\n")
      expect(File.executable?(script)).to be(true)
      expect(text.scan(/https?:\/\/[\w.:-]+/).uniq).to eq([ "http://localhost:3030" ])
      expect(text).not_to match(%r{/home/|/Users/|~/[^.]})
      expect(Open3.capture3("sh", "-n", script).last).to be_success
    end
  end
end
