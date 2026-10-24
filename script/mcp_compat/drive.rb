#!/usr/bin/env ruby
# frozen_string_literal: true

# Replays scenarios.json against an MCP stdio server, one fresh process per scenario
# (mcp-update-plan §3.0 stdio table). Plain Ruby, no gems.
#
#   ruby drive.rb [--report] [--only TEXT] [--timeout SECS] -- <server command...>
#
#   # graph_mem (from the graph_mem checkout, test env, no real Ollama):
#   RAILS_ENV=test OLLAMA_URL=http://127.0.0.1:9 ruby script/mcp_compat/drive.rb -- bundle exec ruby bin/mcp_stdio_runner.rb
#   # Memory 2.0.0 reference (prints answers only):
#   MEMORY_FILE_PATH=$(mktemp) ruby drive.rb --report -- node src/memory/dist/index.js
#
# Checks: every expected reply (by id), the exact reply count, and that every stdout line is a
# JSON-RPC 2.0 message (a non-JSON line, e.g. a log line, breaks strict clients). --report only
# prints what came back. Exit 1 when a check fails.

require "json"
require "open3"
require "optparse"
require "timeout"

options = { report: false, only: nil, timeout: 60.0, settle: 1.5 }
parser = OptionParser.new do |o|
  o.banner = "usage: drive.rb [--report] [--only TEXT] [--timeout SECS] -- <server command...>"
  o.on("--report", "print replies without checking") { options[:report] = true }
  o.on("--only TEXT", "run scenarios whose name includes TEXT") { |v| options[:only] = v }
  o.on("--timeout SECS", Float, "per-scenario timeout (default 60, covers Rails boot)") { |v| options[:timeout] = v }
  o.on("--scenarios PATH", "scenario file (default: scenarios.json next to this script)") { |v| options[:scenarios] = v }
end
args = parser.parse(ARGV)
abort(parser.banner) if args.empty?

scenario_path = options[:scenarios] || File.join(__dir__, "scenarios.json")
scenarios = JSON.parse(File.read(scenario_path, encoding: "UTF-8"))["scenarios"] # UTF-8 whatever the locale
scenarios = scenarios.select { |s| s["name"].include?(options[:only]) } if options[:only]

def encode_line(item)
  return [ item["raw_bytes_hex"] ].pack("H*") if item.is_a?(Hash) && item.key?("raw_bytes_hex")
  return item["raw"] if item.is_a?(Hash) && item.key?("raw")

  JSON.generate(item)
end

# Recursive subset match: every key in +want+ must equal (or subset-match) the one in +got+.
def subset?(want, got)
  return want == got unless want.is_a?(Hash)
  return false unless got.is_a?(Hash)

  want.all? { |key, value| got.key?(key) && subset?(value, got[key]) }
end

# Runs one scenario; returns [parsed replies, non-JSON stdout lines, seconds to the last reply].
def run_scenario(command, scenario, timeout:, settle:)
  expected = scenario["replies"] || scenario["expect"].size
  replies = []
  junk = []
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  last_at = nil

  Open3.popen3(*command) do |stdin, stdout, stderr, wait|
    # Drain stderr (logs) so the server never blocks on it; the stream closes when the scenario ends.
    Thread.new do
      stderr.each_line { nil }
    rescue IOError
      nil
    end
    stdin.binmode
    scenario["send"].each { |item| stdin.write(encode_line(item), "\n") }
    stdin.flush

    deadline = started + timeout
    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # After the expected count, wait +settle+ more seconds for unexpected extra replies.
      limit = replies.size >= expected ? [ last_at + settle, deadline ].min : deadline
      break if now >= limit

      ready = IO.select([ stdout ], nil, nil, limit - now)
      next unless ready

      line = stdout.gets
      break unless line

      begin
        message = JSON.parse(line)
        message.is_a?(Hash) && message["jsonrpc"] == "2.0" ? replies << message : junk << line.chomp
      rescue JSON::ParserError
        junk << line.chomp
      end
      last_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  ensure
    begin
      stdin.close unless stdin.closed?
      Process.kill("TERM", wait.pid)
      Timeout.timeout(5) { wait.value }
    rescue Errno::ESRCH, Timeout::Error
      Process.kill("KILL", wait.pid) rescue nil
    end
  end

  [ replies, junk, last_at && (last_at - started) ]
end

failures = 0
scenarios.each do |scenario|
  replies, junk, seconds = run_scenario(args, scenario, timeout: options[:timeout], settle: options[:settle])
  timing = seconds ? format("%.1fs", seconds) : "no reply"

  if options[:report]
    puts "== #{scenario['name']} (#{timing})"
    replies.each { |r| puts "   #{JSON.generate(r)[0, 240]}" }
    junk.each { |l| puts "   NON-JSON: #{l[0, 200]}" }
    next
  end

  problems = []
  problems << "#{junk.size} non-JSON stdout line(s), first: #{junk.first[0, 120]}" if junk.any?
  want_count = scenario["replies"] || scenario["expect"].size
  problems << "#{replies.size} replies, want #{want_count}" if replies.size != want_count

  null_id_replies = replies.select { |r| r["id"].nil? }
  scenario["expect"].each do |want|
    got = want["id"].nil? ? null_id_replies.shift : replies.find { |r| r["id"] == want["id"] }
    label = "id #{want['id'].inspect}"
    if got.nil?
      problems << "#{label}: no reply"
    elsif want.key?("error_code")
      code = got.dig("error", "code")
      problems << "#{label}: error #{code.inspect}, want #{want['error_code']}" unless code == want["error_code"]
    else
      result = got["result"]
      if result.nil?
        problems << "#{label}: error #{got['error'].inspect}, want a result"
      else
        problems << "#{label}: result #{JSON.generate(result)[0, 160]} doesn't include #{JSON.generate(want['result'])}" if want["result"] && !subset?(want["result"], result)
        missing = Array(want["result_has"]).reject { |key| result.key?(key) }
        problems << "#{label}: result lacks #{missing.join(', ')}" if missing.any?
      end
    end
  end

  if problems.empty?
    puts "PASS #{scenario['name']} (#{timing})"
  else
    failures += 1
    puts "FAIL #{scenario['name']} (#{timing})"
    problems.each { |p| puts "     #{p}" }
  end
end

unless options[:report]
  puts "== #{failures} failed of #{scenarios.size}"
  exit(failures.zero? ? 0 : 1)
end
