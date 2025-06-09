#!/usr/bin/env ruby

# Set RAILS_ENV unless it's already set
ENV['RAILS_ENV'] ||= 'development'

# Load the Rails application
begin
  require_relative '../config/environment'
rescue LoadError => e
  abort "Failed to load Rails environment. Make sure you are in the project root or use 'bundle exec'. Error: #{e.message}"
end

require 'fast_mcp'

# Create a dedicated logger for this runner script, outputting to STDERR
# This ensures these runner-specific logs don't go to STDOUT,
# which must be kept clean for JSON-RPC messages.
RunnerLogger = ::Logger.new(STDERR)
RunnerLogger.level = ENV['RAILS_ENV'] == 'development' ? ::Logger::DEBUG : ::Logger::INFO
RunnerLogger.formatter = proc do |severity, datetime, progname, msg|
  "[GraphMemRunnerScript-#{severity}] #{msg}\n"
end

# Server Info - defined directly, matching your initializer's intent
server_info = {
  name: 'graph-mem', # As per your initializer
  version: GraphMem::VERSION
}
RunnerLogger.info("GraphMem Stdio Runner: Server Name='#{server_info[:name]}', Version='#{server_info[:version]}'")

# Create an FastMcp::Logger instance.
mcp_logger = FastMcp::Logger.new()
RunnerLogger.info("GraphMem Stdio Runner: Initialized FastMcp::Logger (default transport: :stdio).")

# Create the Server instance
server = FastMcp::Server.new(
  name: server_info[:name],
  version: server_info[:version],
  logger: mcp_logger # This logger instance will be used by both Server and StdioTransport
)
RunnerLogger.info("GraphMem Stdio Runner: FastMcp::Server instance created.")

# Register tools with the server
server.register_tools(*ApplicationTool.descendants)
RunnerLogger.info("GraphMem Stdio Runner: Registered #{server.tools.count} tools.")

# Register resources with the server
server.register_resources(*ApplicationResource.descendants)
if server.resources.any?
  RunnerLogger.info("GraphMem Stdio Runner: Registered #{server.resources.count} resources.")
else
  RunnerLogger.info("GraphMem Stdio Runner: No resources were registered.")
end

# Start the server. For v1.4.0, server.start() should handle StdioTransport creation.
RunnerLogger.info("GraphMem Stdio Runner: Calling server.start() to initialize StdioTransport and run...")
begin
  server.start # This will internally create and run StdioTransport
rescue Interrupt
  RunnerLogger.info("GraphMem MCP server (Stdio, via server.start) interrupted. Exiting...")
rescue StandardError => e
  RunnerLogger.error("Error in GraphMem MCP server (Stdio, via server.start): #{e.message}")
  RunnerLogger.error(e.backtrace.join("\n"))
ensure
  RunnerLogger.info("GraphMem MCP server (Stdio, via server.start) stopped.")
end
