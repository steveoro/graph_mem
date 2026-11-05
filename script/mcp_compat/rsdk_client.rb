#!/usr/bin/env ruby
# frozen_string_literal: true

# Connects the official Ruby MCP SDK client (gem `mcp`, RSDK_VERSION, default 1.9.0) to a server,
# lists its tools and counts the ones with a `title` (the 1.9.0 client keeps the field; 1.8.2 drops
# it, so it prints n/a) (mcp-update-plan §3.0 "Real SDK clients", §3.1 step 4).
#
#   ruby rsdk_client.rb stdio auto   -- bundle exec ruby bin/mcp_stdio_runner.rb
#   ruby rsdk_client.rb http  legacy http://127.0.0.1:3999/mcp
#
# Run it with a Ruby that has `mcp` and `faraday` installed, NOT graph_mem's bundle, e.g.
#   rvm use ruby-3.4.12@mcp_compat   (gem install mcp -v 1.8.2; gem install mcp -v 1.9.0; gem install faraday)
# Env: RSDK_VERSION (the `mcp` gem version to load), MCP_TOKEN (HTTP bearer),
#      MCP_CLIENT (X-MCP-Client header, default mcp-compat-rsdk).
# Prints one result line; exit 1 when connect or tools/list fails.

gem "mcp", ENV.fetch("RSDK_VERSION", "1.9.0")
require "mcp"

transport_kind, mode, *target = ARGV
target.shift if target.first == "--"
unless %w[stdio http].include?(transport_kind) && %w[auto legacy].include?(mode) && target.any?
  abort "usage: rsdk_client.rb <stdio|http> <auto|legacy> <url | -- command...>"
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
label = "ruby-sdk #{MCP::VERSION} #{transport_kind} #{mode}"

transport =
  if transport_kind == "stdio"
    MCP::Client::Stdio.new(command: target.first, args: target.drop(1), env: ENV.to_h)
  else
    headers = { "X-MCP-Client" => ENV.fetch("MCP_CLIENT", "mcp-compat-rsdk") }
    headers["Authorization"] = "Bearer #{ENV['MCP_TOKEN']}" if ENV["MCP_TOKEN"]
    MCP::Client::HTTP.new(url: target.first, headers: headers)
  end

client = MCP::Client.new(transport: transport)
begin
  client.connect(client_info: { name: "mcp-compat-rsdk", version: "0" }, mode: mode.to_sym)
  tools = client.tools
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  # MCP::Client::Tool keeps `title` since 1.9.0 (#641); older clients drop it.
  titled = tools.first.respond_to?(:title) ? tools.count { |tool| !tool.title.to_s.strip.empty? } : "n/a"
  puts format("OK   %-32s protocol=%s tools=%d titled=%s %.1fs", label, client.protocol_version, tools.size, titled, seconds)
rescue StandardError => e
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts format("FAIL %-32s %s: %s %.1fs", label, e.class, e.message[0, 200], seconds)
  exit 1
ensure
  transport.close if transport.respond_to?(:close)
end
