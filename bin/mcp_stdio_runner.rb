#!/usr/bin/env ruby

# Set RAILS_ENV unless it's already set
ENV['RAILS_ENV'] ||= 'development'

# Load the Rails application
begin
  require_relative '../config/environment'
rescue LoadError => e
  abort "Failed to load Rails environment. Make sure you are in the project root or use 'bundle exec'. Error: #{e.message}"
end

require 'mcp'
require 'mcp/transports/stdio'

# Create a dedicated logger for this runner script, outputting to STDERR
# This ensures these runner-specific logs don't go to STDOUT,
# which must be kept clean for JSON-RPC messages.
RunnerLogger = ::Logger.new(STDERR)
RunnerLogger.level = ENV['RAILS_ENV'] == 'development' ? ::Logger::DEBUG : ::Logger::INFO
RunnerLogger.formatter = proc do |severity, datetime, progname, msg|
  "[GraphMemRunnerScript-#{severity}] #{msg}\n"
end

# Ensure GraphMem::VERSION is loaded (config/initializers/00_load_version.rb should handle this via environment.rb)
app_version = defined?(GraphMem::VERSION) ? GraphMem::VERSION : '0.2.0-stdio-fallback'

# Server Info - defined directly, matching your initializer's intent
server_info = {
  name: 'graph-mem', # As per your initializer
  version: app_version
}

RunnerLogger.info("GraphMem Stdio Runner: Server Name='#{server_info[:name]}', Version='#{server_info[:version]}'")

# Load tool files to ensure all classes are defined
tool_files = Dir[Rails.root.join('app', 'tools', '**', '*_tool.rb')]
RunnerLogger.info("Found #{tool_files.length} potential tool files")

tool_files.each do |file|
  require file
end

# Get all tool classes (they now inherit directly from MCP::Tool via ApplicationTool)
tool_classes = ApplicationTool.descendants
RunnerLogger.info("Found #{tool_classes.length} tool classes: #{tool_classes.map(&:name)}")

# No conversion needed - tools already inherit from MCP::Tool!
mcp_tool_classes = tool_classes

RunnerLogger.info("Using #{mcp_tool_classes.length} tools directly (no conversion needed)")

# Create the MCP server with the converted tools
server = MCP::Server.new(
  name: server_info[:name],
  version: server_info[:version],
  tools: mcp_tool_classes,
  server_context: {
    rails_env: ENV['RAILS_ENV'],
    app_version: app_version
  }
)

RunnerLogger.info("GraphMem MCP server created with #{mcp_tool_classes.length} tools")

# Create and start the stdio transport
begin
  transport = MCP::Transports::StdioTransport.new(server)
  RunnerLogger.info("GraphMem MCP server starting stdio transport...")
  transport.open
rescue Interrupt
  RunnerLogger.info("GraphMem MCP server interrupted. Exiting...")
rescue StandardError => e
  RunnerLogger.error("Error in GraphMem MCP server: #{e.message}")
  RunnerLogger.error(e.backtrace.join("\n"))
ensure
  RunnerLogger.info("GraphMem MCP server stopped.")
end
