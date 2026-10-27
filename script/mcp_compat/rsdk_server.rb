#!/usr/bin/env ruby
# frozen_string_literal: true

# A minimal server on the official Ruby MCP SDK (gem `mcp`, RSDK_VERSION, default 1.8.2), for
# compare.rb's informational `ruby_sdk` column (mcp-update-plan PR-3 §3.1, Oct 22 additions):
# how the gem graph_mem migrates to (MG-1) answers the same handshake cases. One synthetic,
# read-only tool, `get_current_time`, so the tools/call cases name a tool that exists.
#
#   ruby rsdk_server.rb stdio
#   ruby rsdk_server.rb http 3997      # serves http://127.0.0.1:3997/mcp
#
# Run it with the ruby-3.4.1@mcp_compat gemset (mcp, plus rack, rackup and webrick for http),
# NOT graph_mem's bundle. Loopback only.

gem "mcp", ENV.fetch("RSDK_VERSION", "1.8.2")
require "mcp"
require "time"

class GetCurrentTimeTool < MCP::Tool
  tool_name "get_current_time"
  description "Returns the current time (synthetic compat-test tool)."
  input_schema(properties: {})

  def self.call(server_context: nil)
    MCP::Tool::Response.new([ { type: "text", text: Time.now.utc.iso8601 } ])
  end
end

mode, port = ARGV
server = MCP::Server.new(name: "rsdk-compat", version: MCP::VERSION, tools: [ GetCurrentTimeTool ])

case mode
when "stdio"
  MCP::Server::Transports::StdioTransport.new(server).open
when "http"
  require "rackup"
  transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)
  app = Rack::URLMap.new("/mcp" => transport)
  Rackup::Server.start(app: app, Host: "127.0.0.1", Port: Integer(port || 3997), server: "webrick", AccessLog: [])
else
  abort "usage: rsdk_server.rb stdio | http [PORT]"
end
