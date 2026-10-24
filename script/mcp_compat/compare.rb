#!/usr/bin/env ruby
# frozen_string_literal: true

# Replays the MCP handshake cases (spec/fixtures/mcp/handshakes/) against graph_mem and the v2.0.0
# reference servers, checks each target against its own expectations, and prints how they compare
# (mcp-update-plan PR-3 §3.1 step 3). Plain Ruby, no gems; the reference servers need Node.
#
#   ruby script/mcp_compat/compare.rb [--only TEXT] [--timeout SECS] \
#     [--stdio-graph-mem "CMD"] [--stdio-reference "CMD"] [--stdio-ruby-sdk "CMD"] \
#     [--http-graph-mem URL] [--http-reference URL] [--http-ruby-sdk URL]
#
# Give any subset of targets: one target only checks its expectations; graph_mem and the reference
# together are also compared. Each compared row is "same", "documented divergence", "graph_mem only"
# or "unexpected", by shape and code (status, ids, result or error code), never by message text.
# The ruby_sdk target (rsdk_server.rb, the official `mcp` gem) has no expectations: its rows only
# say whether it answers like graph_mem, as input for the migration (MG-0), and never fail.
# Exit 1 on a failed expectation or an "unexpected" row. See README.md for the commands.

require "net/http"
require "open3"
require "optparse"
require "shellwords"
require "timeout"
require "uri"
require_relative "handshake_cases"

Cases = McpCompat::HandshakeCases

options = { timeout: 60.0, settle: 1.5, targets: {} }
OptionParser.new do |o|
  o.banner = "usage: compare.rb [--only TEXT] [--{stdio,http}-{graph-mem,reference,ruby-sdk} CMD|URL]..."
  o.on("--only TEXT", "run cases whose name includes TEXT") { |v| options[:only] = v }
  o.on("--timeout SECS", Float, "per-case timeout (default 60, covers Rails boot)") { |v| options[:timeout] = v }
  o.on("--stdio-graph-mem CMD", "graph_mem stdio command") { |v| options[:targets][[ :stdio, "graph_mem" ]] = Shellwords.split(v) }
  o.on("--stdio-reference CMD", "Memory 2.0.0 stdio command") { |v| options[:targets][[ :stdio, "reference" ]] = Shellwords.split(v) }
  o.on("--http-graph-mem URL", "graph_mem MCP URL") { |v| options[:targets][[ :http, "graph_mem" ]] = URI(v) }
  o.on("--http-reference URL", "Everything 2.0.0 MCP URL") { |v| options[:targets][[ :http, "reference" ]] = URI(v) }
  o.on("--stdio-ruby-sdk CMD", "rsdk_server.rb stdio command") { |v| options[:targets][[ :stdio, "ruby_sdk" ]] = Shellwords.split(v) }
  o.on("--http-ruby-sdk URL", "rsdk_server.rb MCP URL") { |v| options[:targets][[ :http, "ruby_sdk" ]] = URI(v) }
end.parse!
abort("give at least one target; see --help") if options[:targets].empty?

# --- stdio: one fresh process per case -------------------------------------------------------

# @return [Array(Array<Hash>, Array<String>)] replies and non-JSON-RPC stdout lines
def run_stdio(command, kase, expectation, timeout:, settle:)
  expected = expectation ? expectation["replies"] : nil
  lines = []
  Open3.popen3(*command) do |stdin, stdout, stderr, wait|
    Thread.new do
      stderr.each_line { nil } # drain logs so the server never blocks on them
    rescue IOError
      nil
    end
    stdin.binmode
    kase["send"].each { |item| stdin.write(Cases.stdio_line(item), "\n") }
    stdin.flush
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last_at = started
    deadline = started + timeout
    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Once the expected replies are in (or with no expectation, after a quiet spell), wait
      # +settle+ more seconds for extra ones.
      done = expected.nil? ? lines.any? || now - started > 5 : lines.size >= expected
      limit = done ? [ last_at + settle, deadline ].min : deadline
      break if now >= limit
      next unless stdout.wait_readable(limit - now)

      line = stdout.gets or break
      lines << line
      last_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  ensure
    stop_process(stdin, wait)
  end
  Cases.parse_stdout(lines)
end

def stop_process(stdin, wait)
  stdin.close unless stdin.closed?
  Process.kill("TERM", wait.pid)
  Timeout.timeout(5) { wait.value }
rescue Errno::ESRCH
  nil
rescue Timeout::Error
  Process.kill("KILL", wait.pid)
end

# --- HTTP: one request per case, in a fresh session when the case asks for one ----------------

def http_request(uri, verb, body: nil, headers: {}, read_timeout: 30)
  Net::HTTP.start(uri.host, uri.port, read_timeout: read_timeout) do |http|
    request = Net::HTTP.const_get(verb.capitalize).new(uri)
    Cases::BASE_HEADERS.merge(headers).each { |name, value| request[name] = value }
    request.body = body if body
    response = http.request(request)
    Cases::Response.new(status: response.code.to_i, headers: response.each_header.to_h, body: response.body.to_s)
  end
end

def open_session(uri)
  response = http_request(uri, "post", body: Cases.initialize_body)
  session_id = response.headers["mcp-session-id"]
  http_request(uri, "post", body: JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"),
                            headers: { "Mcp-Session-Id" => session_id, "MCP-Protocol-Version" => Cases::NEW_SESSION_VERSION })
  session_id
end

def close_session(uri, session_id)
  http_request(uri, "delete", headers: { "Mcp-Session-Id" => session_id }) if session_id
rescue StandardError
  nil
end

def run_http(uri, kase)
  session_id = { "new" => -> { open_session(uri) }, "unknown" => -> { "mcp-compat-no-such-session" } }[kase["session"]]&.call
  session_headers = session_id ? { "Mcp-Session-Id" => session_id } : {}
  return second_get_stream(uri, session_headers) if kase["kind"] == "second_get_stream"

  request = kase["request"]
  response = http_request(uri, "post", body: Cases.http_body(request), headers: session_headers.merge(request.fetch("headers", {})))
  close_session(uri, response.headers["mcp-session-id"]) # a session the case's own initialize opened
  response
ensure
  close_session(uri, session_id) if kase["session"] == "new"
end

# Holds one GET stream open and returns the answer to a second one.
def second_get_stream(uri, session_headers)
  stream_headers = session_headers.merge("Accept" => "text/event-stream")
  holder = Thread.new do
    Net::HTTP.start(uri.host, uri.port, read_timeout: 30) do |http|
      request = Net::HTTP::Get.new(uri)
      stream_headers.each { |name, value| request[name] = value }
      http.request(request) { |response| response.read_body { nil } }
    end
  rescue StandardError
    nil
  end
  sleep 1
  http_request(uri, "get", headers: stream_headers, read_timeout: 5)
ensure
  holder&.kill
end

# --- report -----------------------------------------------------------------------------------

failures = 0
unexpected = 0
%i[stdio http].each do |transport|
  targets = [ *Cases::TARGETS, "ruby_sdk" ].filter_map { |target| [ target, options[:targets][[ transport, target ]] ] if options[:targets][[ transport, target ]] }
  next if targets.empty?

  cases = Cases.load(transport)
  cases = cases.select { |kase| kase["name"].include?(options[:only]) } if options[:only]
  puts "== #{transport} (#{targets.map(&:first).join(' vs ')})"
  cases.each do |kase|
    outlines = {}
    notes = []
    targets.each do |target, endpoint|
      expectation = kase.dig("expect", target)
      next notes << "#{target}: not compared (#{kase['divergence']})" if expectation.nil? && target == "reference"

      if transport == :stdio
        replies, junk = run_stdio(endpoint, kase, expectation, timeout: options[:timeout], settle: options[:settle])
        outlines[target] = Cases.stdio_outline(replies)
        problems = expectation ? Cases.check_stdio(expectation, replies: replies, junk: junk) : []
      else
        response = run_http(endpoint, kase)
        outlines[target] = Cases.http_outline(response)
        problems = expectation ? Cases.check_http(expectation, response) : []
      end
      failures += 1 if problems.any?
      notes << (problems.empty? ? "#{target} ok #{outlines[target].inspect}" : "#{target} FAIL: #{problems.join('; ')}")
    end
    if outlines.key?("ruby_sdk") && outlines.key?("graph_mem")
      notes.find { |note| note.start_with?("ruby_sdk") }&.sub!(" ok ", outlines["ruby_sdk"] == outlines["graph_mem"] ? " same as graph_mem " : " differs from graph_mem ")
    end

    compared = targets.any? { |target, _| target == "graph_mem" } && targets.any? { |target, _| target == "reference" }
    verdict = compared ? Cases.classify(kase, outlines["graph_mem"], outlines["reference"]) : nil
    unexpected += 1 if verdict == "unexpected"
    status = notes.any? { |note| note.include?(" FAIL") } || verdict == "unexpected" ? "FAIL" : "PASS"
    puts "#{status} #{kase['name']}#{verdict ? " [#{verdict}]" : ''}"
    notes.each { |note| puts "     #{note}" }
  end
end

puts "== #{failures} failed expectation(s), #{unexpected} unexpected difference(s)"
exit(failures.zero? && unexpected.zero? ? 0 : 1)
