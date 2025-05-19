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

# --- BEGIN DEBUG MONKEY PATCH for FastMcp::Logger ---
# This patch makes FastMcp::Logger instances also write their logs to STDERR,
# allowing visibility into FastMcp::Server and StdioTransport internal logging
# when their own logger (which is a FastMcp::Logger) is used.
if ENV['RAILS_ENV'] == 'development' # Apply patch only in development
  Rails.logger.info("[RunnerLog] Applying FastMcp::Logger debug patch to redirect its output to STDERR.")
  module FastMcp
    class Logger
      # Store the original 'add' method if not already done
      unless instance_methods.include?(:original_add_for_mcp_stderr_debug)
        alias_method :original_add_for_mcp_stderr_debug, :add
      end

      # Override 'add' to also log to a dedicated STDERR logger
      def add(severity, message = nil, progname = nil, &block)
        # Initialize a dedicated STDERR logger for this FastMcp::Logger instance if not present
        @stderr_debug_logger_instance ||= begin
          logger = ::Logger.new(STDERR)
          logger.level = self.level # Use the level set on this FastMcp::Logger instance
          logger.formatter = proc do |s, datetime, p, msg|
            "[FastMcpInternal-#{s}] #{msg}\n"
          end
          logger
        end

        # Log the message using the dedicated STDERR logger
        @stderr_debug_logger_instance.add(severity, message, progname, &block)

        # Call the original 'add' method. For :stdio transport, this is a no-op.
        # For other transports, it would log to STDOUT if originally configured to do so.
        original_add_for_mcp_stderr_debug(severity, message, progname, &block)
      end
    end
  end
end
# --- END DEBUG MONKEY PATCH ---

# Ensure GraphMem::VERSION is loaded (config/initializers/00_load_version.rb should handle this via environment.rb)
app_version = defined?(GraphMem::VERSION) ? GraphMem::VERSION : '0.2.0-stdio-fallback'

# Server Info - defined directly, matching your initializer's intent
server_info = {
  name: 'graph-mem', # As per your initializer
  version: app_version
}

Rails.logger.info("GraphMem Stdio Runner: Server Name='#{server_info[:name]}', Version='#{server_info[:version]}'")

# Manually list and instantiate your tool classes.
# These should match the tools registered in config/initializers/fast_mcp.rb
tool_classes = [
  CreateEntityTool,
  CreateObservationTool,
  CreateRelationTool,
  DeleteEntityTool,
  DeleteObservationTool,
  DeleteRelationTool,
  FindRelationsTool,
  GetEntityTool,
  SearchEntitiesTool,
  VersionTool
]

tools_instances = tool_classes.map do |tool_class|
  begin
    tool_class.new
  rescue StandardError => e
    Rails.logger.error "Failed to instantiate tool: #{tool_class.name}. Error: #{e.message}"
    nil
  end
end.compact

Rails.logger.info("GraphMem Stdio Runner: Prepared #{tools_instances.length} tool instances.")

# Manually instantiate resources
resources_instances = []
if Object.const_defined?('SampleResource') && SampleResource.respond_to?(:new)
  begin
    # Assuming SampleResource might take arguments or need specific setup not shown.
    # For now, simple instantiation.
    resources_instances << SampleResource.new
    Rails.logger.info("GraphMem Stdio Runner: Prepared SampleResource instance.")
  rescue StandardError => e
    Rails.logger.error "Failed to instantiate SampleResource. Error: #{e.message}"
  end
else
  Rails.logger.warn("GraphMem Stdio Runner: SampleResource class not found or not instantiable.")
end

# Create an FastMcp::Logger instance.
# For fast-mcp v1.4.0, FastMcp::Logger.new() defaults to `transport: :stdio`,
# which makes its `add` method a no-op for STDOUT.
# Our patch above makes it also log to STDERR.
mcp_logger = FastMcp::Logger.new()
Rails.logger.info("GraphMem Stdio Runner: Initialized FastMcp::Logger (default transport: :stdio). Patched to also log to STDERR.")

# Create the Server instance
server = FastMcp::Server.new(
  name: server_info[:name],
  version: server_info[:version],
  logger: mcp_logger # This logger instance will be used by both Server and StdioTransport
)

Rails.logger.info("GraphMem Stdio Runner: FastMcp::Server instance created.")

# Register tools with the server
tools_instances.each do |tool_instance|
  server.register_tool(tool_instance)
end
Rails.logger.info("GraphMem Stdio Runner: Registered #{server.tools.count} tools with the server.")

# Register resources with the server
resources_instances.each do |resource_instance|
  server.register_resource(resource_instance)
end
if resources_instances.any?
  Rails.logger.info("GraphMem Stdio Runner: Registered #{server.resources.count} resources with the server.")
else
  Rails.logger.info("GraphMem Stdio Runner: No resources were registered with the server.")
end

# Start the server. For v1.4.0, server.start() should handle StdioTransport creation.
Rails.logger.info("GraphMem Stdio Runner: Calling server.start() to initialize StdioTransport and run...")
begin
  server.start # This will internally create and run StdioTransport
rescue Interrupt
  Rails.logger.info("GraphMem MCP server (Stdio, via server.start) interrupted. Exiting...")
rescue StandardError => e
  Rails.logger.error("Error in GraphMem MCP server (Stdio, via server.start): #{e.message}")
  Rails.logger.error(e.backtrace.join("\n"))
ensure
  Rails.logger.info("GraphMem MCP server (Stdio, via server.start) stopped.")
end
