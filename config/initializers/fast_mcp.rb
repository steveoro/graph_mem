# frozen_string_literal: true

require_relative "../../lib/graph_mem/version"
require "fast_mcp"
require_relative "../../lib/graph_mem/mcp_tool_registry"
require_relative "../../lib/graph_mem/mcp_server_patch"
require_relative "../../lib/graph_mem/mcp_streamable_http_transport"

# Toggle this to enable/disable debug output
debug_mode = false

# Clear any existing FastMcp server instance if Rails reloads initializers
# This helps prevent issues with stale server instances in development.
if Rails.env.development? && defined?(FastMcp.server) && FastMcp.server
  puts "[DEBUG] FastMcp Initializer: Clearing existing FastMcp.server instance" if debug_mode
  FastMcp.server = nil
end

puts "[DEBUG] FastMcp Initializer: Starting setup..." if debug_mode

# Configure FastMcp logger
fast_mcp_logger = Logger.new(STDOUT)
fast_mcp_logger.level = Logger::DEBUG # Or your preferred level (INFO, WARN, ERROR)

server = FastMcp::Server.new(
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: GraphMem::VERSION.to_s,
  logger: fast_mcp_logger
)

Rails.application.config.after_initialize do
  GraphMem::McpToolRegistry.register_with!(server)
end

# Re-register after code reload so new tool files appear without a full restart.
if Rails.env.development?
  Rails.application.config.to_prepare do
    GraphMem::McpToolRegistry.register_with!(FastMcp.server) if FastMcp.server
  end
end

# Mount the combined Streamable HTTP + legacy SSE transport.
Rails.application.config.middleware.use(
  GraphMem::McpStreamableHttpTransport,
  server,
  path_prefix: "/mcp",
  messages_route: "messages",
  sse_route: "sse",
  allowed_origins: [ "localhost", "127.0.0.1", "::1", /\A192\.168\.\d{1,3}\.\d{1,3}\z/, /\A10\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/ ],
  localhost_only: false,
  allowed_ips: [ "127.0.0.1", "::1", "::ffff:127.0.0.1" ]
)

FastMcp.server = server

puts "[DEBUG] FastMcp Initializer: Finished setup using GraphMem::McpStreamableHttpTransport." if debug_mode
