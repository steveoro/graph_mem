#!/usr/bin/env ruby

# GraphMem MCP server over stdio.
#
# stdout carries JSON-RPC and nothing else (mcp plan PR-2 §2.13): before Rails loads, the real
# stdout is kept for the transport and STDOUT / $stdout are pointed at stderr, so a stray `puts`
# or Logger.new(STDOUT) anywhere in the app can't corrupt the stream. Strict clients (the Ruby
# MCP SDK) fail on any non-JSON line.
#
# Boot has no side effects (no jobs, migrations or locks), so a client that starts the runner
# only to probe server/discover and kills it within a second leaves nothing behind. Clients that
# probe can skip it with MCP_PROTOCOL_NEGOTIATION=legacy.

mcp_out = STDOUT.dup
mcp_out.sync = true
STDOUT.reopen(STDERR)
$stdout = $stderr
ENV["GRAPH_MEM_MCP_STDIO"] = "1"

# Set RAILS_ENV unless it's already set
ENV['RAILS_ENV'] ||= 'development'

# Load the Rails application
begin
  require_relative '../config/environment'
rescue LoadError => e
  abort "Failed to load Rails environment. Make sure you are in the project root or use 'bundle exec'. Error: #{e.message}"
end

# Rails logs to stderr too (production points Rails.logger at STDOUT).
Rails.logger = ActiveSupport::Logger.new($stderr)
ActiveRecord::Base.logger = Rails.logger

RunnerLogger = ::Logger.new($stderr)
RunnerLogger.level = ENV['RAILS_ENV'] == 'development' ? ::Logger::DEBUG : ::Logger::INFO
RunnerLogger.formatter = proc do |severity, _datetime, _progname, msg|
  "[GraphMemRunnerScript-#{severity}] #{msg}\n"
end

server_info = { name: 'graph-mem', version: GraphMem::VERSION }
RunnerLogger.info("GraphMem Stdio Runner: Server Name='#{server_info[:name]}', Version='#{server_info[:version]}'")

begin
  profile = GraphMem::McpProfile.from_env
rescue GraphMem::McpProfile::InvalidProfile => e
  abort "GraphMem Stdio Runner: #{e.message}"
end

server = GraphMem::OfficialMcp::ServerFactory.for(profile)
RunnerLogger.info(
  "GraphMem Stdio Runner: serving #{server.tools.count} tools, #{server.prompts.count} prompts and " \
  "#{server.resource_templates.count} resource templates for the #{profile} profile."
)

begin
  # Responses go to the saved real stdout. A line over GRAPH_MEM_MCP_MAX_REQUEST_BYTES ends the
  # session (the gem's behaviour, D7).
  GraphMem::OfficialMcp::StdioTransport.new(server, output: mcp_out).open
rescue Interrupt
  RunnerLogger.info("GraphMem MCP server (stdio) interrupted. Exiting...")
rescue StandardError => e
  RunnerLogger.error("Error in GraphMem MCP server (stdio): #{e.message}")
  RunnerLogger.error(e.backtrace.join("\n"))
ensure
  RunnerLogger.info("GraphMem MCP server (stdio) stopped.")
end
