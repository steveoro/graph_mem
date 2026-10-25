# frozen_string_literal: true

# Claude Code as the MCP client against a local graph_mem: the automated version of
# docs/plans/claude-mcp-client-check.md (Parts A, B and C).
#
#   script/mcp_compat/claude_client_check.rb [--model NAME] [--budget USD] [--port N]
#                                            [--only default|legacy] [--timeout SECONDS]
#
# Run it from the graph_mem checkout with the graph_mem Ruby (it loads the app in the test
# environment and refuses any database but graph_mem's test one). Don't run it alongside rspec:
# both use the test database, and the cleanup removes rows created during the run. It:
# 1. starts graph_mem in-process on a loopback port, with a throwaway bearer token and synthetic scan
#    folders, behind a tap that records the protocol version each client uses;
# 2. runs Part A's checks directly over HTTP and stdio (N1–N5, plus the prompts);
# 3. runs Part B twice through `claude -p` (default negotiation, then MCP_PROTOCOL_NEGOTIATION=legacy)
#    with only the five check servers and no built-in tools except the MCP resource tools;
# 4. checks graph_mem's side independently of what the agent reports: which servers connected, which
#    prompts each profile offered, the protocol version each client used for its tool calls, the
#    tools each client really called (tool_invocations), and that no McpCheck entity is left;
# 5. prints the results table and exits 1 if any check failed.
#
# Costs: each Part B run is one Claude Code session (capped by --budget, default 3 USD per run, and by
# --timeout, default 900 s). Nothing here touches your own Claude Code MCP configuration: the servers
# are passed with --mcp-config/--strict-mcp-config from a scratch folder that is deleted at the end.

require "json"
require "open3"
require "optparse"
require "securerandom"
require "timeout"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
CHECK_DIR = File.join(__dir__, "claude_client_check")
MIN_CLAUDE_VERSION = Gem::Version.new("2.1.296")
VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"

# --- stdio tap: `claude_client_check.rb --stdio-tap LOG -- cmd...` -----------------------------------
# Claude Code starts this as the gm-stdio server. It runs the real runner and logs, for each
# tools/call, the protocol version in use: the request's 2026-07-28 `_meta` version, or else the
# version the `initialize` handshake settled on. It also logs how long the first answer took.
if ARGV.first == "--stdio-tap"
  log_path = ARGV[1]
  command = ARGV.drop(3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  log = ->(entry) { File.open(log_path, "a") { |file| file.puts(JSON.generate(entry)) } }
  Open3.popen2(*command) do |child_in, child_out, wait|
    pending = {}
    handshake = nil
    first_reply = true
    reader = Thread.new do
      child_out.each_line do |line|
        $stdout.write(line)
        $stdout.flush
        if first_reply
          first_reply = false
          log.call(first_reply_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1))
        end
        reply = JSON.parse(line) rescue next
        handshake = reply.dig("result", "protocolVersion") if pending.delete(reply["id"]) == "initialize"
      end
    end
    $stdin.each_line do |line|
      message = JSON.parse(line) rescue nil
      if message.is_a?(Hash)
        pending[message["id"]] = message["method"] if message["id"]
        if message["method"] == "tools/call"
          log.call(tool_call_version: message.dig("params", "_meta", VERSION_META_KEY) || handshake)
        end
      end
      child_in.write(line)
      child_in.flush
    end
    child_in.close
    reader.join
    exit(wait.value.exitstatus || 1)
  end
end

options = { model: nil, budget: "3", port: 3995, only: nil, timeout: 900 }
OptionParser.new do |parser|
  parser.on("--model NAME", "Claude model for Part B (default: your Claude Code default)") { |value| options[:model] = value }
  parser.on("--budget USD", "Max spend per Part B run (default 3)") { |value| options[:budget] = value }
  parser.on("--port N", Integer, "Loopback port for graph_mem (default 3995)") { |value| options[:port] = value }
  parser.on("--only MODE", %w[default legacy], "Run Part B in one negotiation mode only") { |value| options[:only] = value }
  parser.on("--timeout SECONDS", Integer, "Time limit per Part B run (default 900)") { |value| options[:timeout] = value }
end.parse!

claude_version = `claude --version 2>/dev/null`[/\d+\.\d+\.\d+/]
abort "claude CLI not found on PATH" unless claude_version
abort "Claude Code #{claude_version} is older than #{MIN_CLAUDE_VERSION}" if Gem::Version.new(claude_version) < MIN_CLAUDE_VERSION

# Runs a command with a time limit. @return [Array(String, String, Process::Status, Boolean)] stdout,
# stderr, status (nil when killed) and whether it timed out
def run_with_timeout(env, command, seconds:, chdir:, stdin_data: "")
  Open3.popen3(env, *command, chdir: chdir) do |stdin, stdout, stderr, wait|
    readers = [ stdout, stderr ].map { |io| Thread.new { io.read } }
    stdin.write(stdin_data)
    stdin.close
    unless wait.join(seconds)
      begin
        Process.kill("TERM", wait.pid)
        wait.join(5) || Process.kill("KILL", wait.pid)
      rescue Errno::ESRCH
        nil
      end
      # A stuck grandchild (e.g. a stdio server) can hold the pipes open: don't wait for it forever.
      return [ (readers[0].join(5)&.value).to_s, (readers[1].join(5)&.value).to_s, nil, true ]
    end
    [ readers[0].value, readers[1].value, wait.value, false ]
  end
end

# Buffers each JSON response once (the body is handed back as an array) and records, per X-MCP-Client,
# the protocol version of every tools/call: the MCP-Protocol-Version header, or else the version the
# client's `initialize` settled on.
class ProtocolTap
  attr_reader :tool_call_versions

  def initialize(app)
    @app = app
    @handshakes = {}
    @tool_call_versions = Hash.new { |hash, key| hash[key] = [] }
    @mutex = Mutex.new
  end

  def call(env)
    client = env["HTTP_X_MCP_CLIENT"] || "-"
    method = request_method(env)
    if method == "tools/call"
      version = env["HTTP_MCP_PROTOCOL_VERSION"] || @mutex.synchronize { @handshakes[client] }
      @mutex.synchronize { @tool_call_versions[client] << version }
    end
    status, headers, body = @app.call(env)
    return [ status, headers, body ] unless method == "initialize" && body.respond_to?(:each)

    text = +""
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    negotiated = (JSON.parse(text[/\{.*\}/m] || "{}").dig("result", "protocolVersion") rescue nil)
    @mutex.synchronize { @handshakes[client] = negotiated } if negotiated
    [ status, headers, [ text ] ]
  end

  private

  def request_method(env)
    return unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"].to_s.start_with?("/mcp")

    body = env["rack.input"].read
    env["rack.input"].rewind
    message = JSON.parse(body)
    message["method"] if message.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end
end

def http(base, path, body: nil, headers: {}, raw: nil)
  uri = URI("#{base}#{path}")
  request = Net::HTTP::Post.new(uri)
  { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }.merge(headers).each { |key, value| request[key] = value }
  request.body = raw || JSON.generate(body)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 60) { |connection| connection.request(request) }
  [ response, (JSON.parse(response.body) rescue nil) ]
end

work = nil
server = nil
started_at = nil
check_clients = %w[http ro maint].flat_map { |name| %w[default legacy].map { |mode| "claude-check-#{name}-#{mode}" } }
results = []
add = ->(part, check, pass, detail) { results << { part: part, check: check, pass: pass, detail: detail.to_s } }
graph_mem_version = "?"
commit = (Open3.capture2("git", "-C", ROOT, "rev-parse", "--short", "HEAD", err: File::NULL).first.strip rescue "")
commit = "?" if commit.empty?

begin
  work = Dir.mktmpdir("gm-client-check")
  scan_root = File.join(work, "root")
  synth = File.join(scan_root, "Projects", "mcp-check-synth")
  outside = File.join(scan_root, "McpCheckOutside")
  hidden = File.join(scan_root, ".ssh")
  [ File.join(synth, "lib"), outside, hidden ].each { |dir| FileUtils.mkdir_p(dir) }
  File.write(File.join(synth, "lib", "synth_widget.rb"), "class SynthWidget\n  def ping = :pong\nend\n")
  File.write(File.join(synth, "README.md"), "# mcp-check-synth\nSynthetic fixture for the MCP client check.\n")

  token = SecureRandom.hex(32)
  ENV["RAILS_ENV"] = "test"
  ENV["OLLAMA_URL"] = "http://127.0.0.1:9"
  ENV.delete("SUMMARY_URL")
  ENV["GRAPH_MEM_MCP_TOKEN"] = token
  ENV["GRAPH_MEM_SCAN_ROOTS"] = scan_root
  require File.join(ROOT, "config/environment")
  database = ActiveRecord::Base.connection_db_config.database.to_s
  unless database.end_with?("_test")
    abort "Refusing to run against #{database}: the cleanup deletes rows created during the run, so use the test database"
  end
  started_at = Time.current
  graph_mem_version = GraphMem::VERSION
  require "puma"
  require "puma/server"

  tap_app = ProtocolTap.new(Rails.application)
  server = Puma::Server.new(tap_app, nil, min_threads: 4, max_threads: 16, log_writer: Puma::LogWriter.null)
  begin
    server.add_tcp_listener("127.0.0.1", options[:port])
  rescue Errno::EADDRINUSE
    server = nil
    abort "Port #{options[:port]} is busy: pass another one with --port"
  end
  server.run
  base = "http://localhost:#{options[:port]}"

  auth = { "Authorization" => "Bearer #{token}" }
  init_body = { jsonrpc: "2.0", id: 1, method: "initialize",
                params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "client-check", version: "0" } } }

  # --- Part A ----------------------------------------------------------------------------------------
  response, = http(base, "/mcp", body: init_body, headers: { "Authorization" => "Bearer wrong-token" })
  add.call("A", "N1 wrong token → 401 + WWW-Authenticate", response.code == "401" && response["WWW-Authenticate"] == 'Bearer realm="graph_mem"',
           "#{response.code} #{response['WWW-Authenticate']}")

  lines = [ init_body, { jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", id: 2, method: "tools/list" } ].map { |message| JSON.generate(message) }
  stdio_env = { "RAILS_ENV" => "test", "OLLAMA_URL" => "http://127.0.0.1:9", "GRAPH_MEM_MCP_PROFILE" => "maintenance", "GRAPH_MEM_SCAN_ROOTS" => scan_root }
  out, _err, _status, timed_out = run_with_timeout(stdio_env, [ RbConfig.ruby, File.join(ROOT, "bin/mcp_stdio_runner.rb") ],
                                                   seconds: 120, chdir: ROOT, stdin_data: lines.join("\n") + "\n")
  parsed = out.lines.map { |line| JSON.parse(line) rescue :noise }
  add.call("A", "N2 stdio stdout is JSON-RPC only", !timed_out && parsed.none?(:noise) && parsed.size == 2 && parsed.last.dig("result", "tools")&.size == 22,
           "#{'timed out; ' if timed_out}#{parsed.count { |line| line != :noise }} JSON lines, #{parsed.count(:noise)} other, " \
           "#{parsed.last.is_a?(Hash) ? parsed.last.dig('result', 'tools')&.size : '-'} tools")

  response, initialized = http(base, "/mcp", body: init_body, headers: auth)
  session = { "Mcp-Session-Id" => response["Mcp-Session-Id"], "MCP-Protocol-Version" => "2025-11-25" }.merge(auth)
  http(base, "/mcp", body: { jsonrpc: "2.0", method: "notifications/initialized" }, headers: session)
  write = { name: "graph_write", arguments: { operations: [ { type: "create_entity", name: "McpCheck NullId", entity_type: "Component" } ] } }
  null_response, null_body = http(base, "/mcp", body: { jsonrpc: "2.0", id: nil, method: "tools/call", params: write }, headers: session)
  blind_response, = http(base, "/mcp", body: { jsonrpc: "2.0", method: "tools/call", params: write }, headers: session)
  add.call("A", "N3 \"id\": null refused, id-less accepted, neither ran",
           null_body&.dig("error", "code") == -32_600 && !null_body.key?("id") && blind_response.code == "202" && !MemoryEntity.exists?(name: "McpCheck NullId"),
           "null id: #{null_response.code} #{null_body&.dig('error', 'code')}; id-less: #{blind_response.code}; McpCheck NullId exists: #{MemoryEntity.exists?(name: 'McpCheck NullId')}")

  utf8_response, utf8_body = http(base, "/mcp", raw: "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"\xff\":1}".b, headers: session)
  add.call("A", "N4 invalid UTF-8 key → 400 -32700, no id", utf8_response.code == "400" && utf8_body&.dig("error", "code") == -32_700 && !utf8_body&.key?("id"),
           "#{utf8_response.code} #{utf8_body&.dig('error', 'code')}")

  capabilities = initialized&.dig("result", "capabilities")
  add.call("A", "N5 capabilities and instructions",
           capabilities == GraphMem::OfficialMcp::ServerFactory::CAPABILITIES.deep_stringify_keys && initialized.dig("result", "instructions").present?,
           capabilities.to_json)

  prompt = lambda do |path, name, arguments|
    init_response, init = http(base, path, body: init_body, headers: auth)
    _, body = http(base, path, body: { jsonrpc: "2.0", id: 3, method: "prompts/get", params: { name: name, arguments: arguments } },
                               headers: auth.merge("Mcp-Session-Id" => init_response["Mcp-Session-Id"], "MCP-Protocol-Version" => "2025-11-25"))
    init && body
  end
  rendered = %w[orient persist].map { |name| prompt.call("/mcp", name, {}) } << prompt.call("/mcp", "recall", { topic: "McpCheck" })
  no_topic = prompt.call("/mcp", "recall", {})
  ro_persist = prompt.call("/mcp/readonly", "persist", {})
  add.call("A", "Prompts: orient, recall, persist render; recall needs a topic; no persist on readonly",
           rendered.all? { |body| body&.dig("result", "messages")&.any? } && no_topic&.dig("error", "code") == -32_602 && ro_persist&.dig("error", "code") == -32_602,
           "rendered #{rendered.count { |body| body&.dig('result', 'messages')&.any? }}/3; recall without topic #{no_topic&.dig('error', 'code')}; " \
           "readonly persist #{ro_persist&.dig('error', 'code')}")

  # --- Part B (twice) and Part C ---------------------------------------------------------------------
  # gm-stdio runs this interpreter with Bundler's own executable and the current gem paths, so it uses
  # the same Ruby and gems as this script whatever PATH Claude Code gives its stdio servers.
  bundle_args = [ Gem.bin_path("bundler", "bundle"), "exec", RbConfig.ruby, File.join(ROOT, "bin/mcp_stdio_runner.rb") ]
  gem_env = { "GEM_HOME" => ENV["GEM_HOME"], "GEM_PATH" => ENV["GEM_PATH"], "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }.compact
  modes = options[:only] ? [ options[:only] ] : %w[default legacy]
  modes.each do |mode|
    clients = %w[http ro maint].to_h { |name| [ name, "claude-check-#{name}-#{mode}" ] }
    stdio_log = File.join(work, "stdio-#{mode}.log")
    config = { mcpServers: {
      "gm-http" => { type: "http", url: "#{base}/mcp", headers: { "Authorization" => "Bearer #{token}", "X-MCP-Client" => clients["http"] } },
      "gm-ro" => { type: "http", url: "#{base}/mcp/readonly", headers: { "Authorization" => "Bearer #{token}", "X-MCP-Client" => clients["ro"] } },
      "gm-maint" => { type: "http", url: "#{base}/mcp/maintenance", headers: { "Authorization" => "Bearer #{token}", "X-MCP-Client" => clients["maint"] } },
      "gm-badtoken" => { type: "http", url: "#{base}/mcp", headers: { "Authorization" => "Bearer wrong-token" } },
      "gm-stdio" => { type: "stdio", command: RbConfig.ruby,
                      args: [ File.expand_path(__FILE__), "--stdio-tap", stdio_log, "--", RbConfig.ruby, *bundle_args ],
                      env: stdio_env.merge(gem_env) }
    } }
    cwd = File.join(work, "client-#{mode}")
    FileUtils.mkdir_p(cwd)
    File.write(File.join(cwd, "mcp.json"), JSON.generate(config))
    prompt_text = File.read(File.join(CHECK_DIR, "prompt.md")).gsub("{{SYNTH}}", synth).gsub("{{OUTSIDE}}", outside).gsub("{{HIDDEN}}", hidden)
    command = [ "claude", "-p", prompt_text, "--mcp-config", "mcp.json", "--strict-mcp-config", "--setting-sources", "project",
                "--tools", "ListMcpResourcesTool,ReadMcpResourceTool",
                "--allowedTools", "mcp__gm-http__*,mcp__gm-ro__*,mcp__gm-maint__*,mcp__gm-stdio__*,ListMcpResourcesTool,ReadMcpResourceTool",
                "--json-schema", File.read(File.join(CHECK_DIR, "schema.json")),
                "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--max-budget-usd", options[:budget] ]
    command += [ "--model", options[:model] ] if options[:model]
    client_env = mode == "legacy" ? { "MCP_PROTOCOL_NEGOTIATION" => "legacy" } : {}
    run_started = Time.current
    puts "Part B (#{mode}): running Claude Code (up to #{options[:timeout]} s)…"
    stream, err, status, timed_out = run_with_timeout(client_env, command, seconds: options[:timeout], chdir: cwd)
    clean = status&.success? && !timed_out
    reason = timed_out ? "timed out after #{options[:timeout]} s" : "exit #{status&.exitstatus}: #{err.gsub(token, '[token]').lines.last(3).join(' ').strip}"
    add.call(mode, "Claude Code exited cleanly", clean, clean ? "exit 0" : reason)

    events = stream.lines.filter_map { |line| JSON.parse(line) rescue nil }
    init = events.find { |event| event["type"] == "system" && event["subtype"] == "init" } || {}
    final = events.reverse.find { |event| event["type"] == "result" } || {}
    report = final["structured_output"] || (JSON.parse(final["result"].to_s[/\{.*\}/m] || "{}") rescue {})

    statuses = Array(init["mcp_servers"]).to_h { |entry| [ entry["name"], entry["status"] ] }
    add.call(mode, "Connections: 4 connected, gm-badtoken failed",
             %w[gm-http gm-ro gm-maint gm-stdio].all? { |name| statuses[name] == "connected" } && statuses["gm-badtoken"] == "failed", statuses.to_json)
    commands = Array(init["slash_commands"])
    add.call(mode, "Prompts offered: 3 on gm-http, no persist on gm-ro",
             %w[orient recall persist].all? { |name| commands.include?("mcp__gm-http__#{name}") } &&
               %w[orient recall].all? { |name| commands.include?("mcp__gm-ro__#{name}") } && !commands.include?("mcp__gm-ro__persist"),
             commands.grep(/\Amcp__/).join(" "))

    stdio_entries = File.exist?(stdio_log) ? File.readlines(stdio_log).map { |line| JSON.parse(line) } : []
    used = clients.transform_values { |client| tap_app.tool_call_versions[client].uniq }
                  .merge("stdio" => stdio_entries.filter_map { |entry| entry["tool_call_version"] }.uniq)
    expected = mode == "legacy" ? "2025-11-25" : "2026-07-28"
    add.call(mode, "Protocol used for tool calls: #{expected}", used.values.all? { |versions| versions == [ expected ] }, used.to_json)
    connect = stdio_entries.find { |entry| entry["first_reply_seconds"] }&.fetch("first_reply_seconds")
    add.call(mode, "First stdio answer (seconds, informational)", true, connect || "n/a")

    calls = ToolInvocation.where(created_at: run_started..)
    ro_writes = calls.where(client_id: clients["ro"], tool_name: %w[graph_write graph_edit graph_delete]).count
    ro_time = calls.where(client_id: clients["ro"], tool_name: "get_current_time").exists?
    add.call(mode, "Server side: gm-ro called get_current_time and no write tool", ro_time && ro_writes.zero?,
             "get_current_time: #{ro_time ? 'called' : 'not called'}; #{ro_writes} write calls")
    http_tools = calls.where(client_id: clients["http"]).distinct.pluck(:tool_name)
    expected_http = %w[get_current_time graph_write set_context get_context search get_entities traverse_graph find_shortest_path rank_observations summarize graph_edit graph_delete]
    add.call(mode, "Server side: gm-http called the 12 tools", (expected_http - http_tools).empty?, "missing: #{(expected_http - http_tools).join(', ').presence || 'none'}")
    scan_errors = calls.where(client_id: clients["maint"], tool_name: "scan_project", outcome: "error").count
    maint_tools = calls.where(client_id: clients["maint"]).distinct.pluck(:tool_name)
    add.call(mode, "Server side: gm-maint refused 4 scans, ran the dry run, status and the Project delete",
             scan_errors >= 4 && (%w[scan_project scan_project_status get_graph_stats list_maintenance_review graph_delete] - maint_tools).empty?,
             "#{scan_errors} refused scans; tools: #{maint_tools.sort.join(', ')}")
    stdio_tools = calls.where(client_id: GraphMemContext::DEFAULT_CLIENT_ID).distinct.pluck(:tool_name)
    add.call(mode, "Server side: gm-stdio called get_current_time, search, scan_project", (%w[get_current_time search scan_project] - stdio_tools).empty?,
             stdio_tools.sort.join(", "))
    leftovers = MemoryEntity.where("name LIKE ?", "McpCheck%").pluck(:name)
    add.call(mode, "Server side: no McpCheck entity left", leftovers.empty?, leftovers.join(", ").presence || "none")

    steps = Array(report["steps"])
    failed = steps.reject { |step| step["pass"] }
    add.call(mode, "Agent report: #{steps.size} steps, all PASS", steps.size >= 22 && failed.empty?,
             failed.map { |step| "#{step['step']} #{step['server']}: #{step['actual']}" }.join(" | ").presence || "cost #{final['total_cost_usd']&.round(2)} USD")
    add.call(mode, "Agent: anything odd", true, report["odd"].presence || "nothing")

    MemoryEntity.where("name LIKE ?", "McpCheck%").destroy_all
    GraphMemContext.for(clients["http"]).clear!
  end
ensure
  server&.stop(true)
  if started_at
    MemoryEntity.where("name LIKE ?", "McpCheck%").destroy_all
    [ ToolInvocation, AgentContext, AuditLog, MemoryRelation, MemoryObservation, OperationProgress ].each { |model| model.where(created_at: started_at..).delete_all }
    AgentContext.where(client_id: check_clients).delete_all
  end
  FileUtils.remove_entry(work) if work && File.directory?(work)
end

puts "\nClaude Code #{claude_version} · graph_mem #{graph_mem_version} (#{commit}) · #{Time.now.strftime('%Y-%m-%d %H:%M')}\n\n"
puts "| Part | Check | Result | Detail |"
puts "| --- | --- | --- | --- |"
results.each { |row| puts "| #{row[:part]} | #{row[:check]} | #{row[:pass] ? 'PASS' : 'FAIL'} | #{row[:detail].tr('|', '/')[0, 300]} |" }
failures = results.count { |row| !row[:pass] }
puts "\n#{failures.zero? ? 'All checks passed.' : "#{failures} check(s) failed."}"
exit(failures.zero? ? 0 : 1)
