# frozen_string_literal: true

require_relative "../../lib/graph_mem/version" # Ensure GraphMem::VERSION is loaded
require "fast_mcp"

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

FastMcp.mount_in_rails(
  Rails.application,
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: GraphMem::VERSION.to_s,
  path_prefix: "/mcp", # This is the default path prefix
  messages_route: "messages", # This is the default route for the messages endpoint
  sse_route: "sse", # This is the default route for the SSE endpoint
  # Add allowed origins below, it defaults to Rails.application.config.hosts
  # allowed_origins: ['localhost', '127.0.0.1', 'example.com', /.*\.example\.com/],
  # localhost_only: true, # Set to false to allow connections from other hosts
  # whitelist specific ips to if you want to run on localhost and allow connections from other IPs
  # allowed_ips: ['127.0.0.1', '::1']
  # authenticate: true,       # Uncomment to enable authentication
  # auth_token: 'your-token' # Required if authenticate: true
) do |server|
  Rails.application.config.after_initialize do
    # FastMcp will automatically discover and register:
    # - All classes that inherit from ApplicationTool (which uses ActionTool::Base)
    # - All classes that inherit from ApplicationResource (which uses ActionResource::Base)
    server.register_tools(*ApplicationTool.descendants)
    server.register_resources(*ApplicationResource.descendants)
    # alternatively, you can register tools and resources manually:
    # server.register_tool(MyTool)
    # server.register_resource(MyResource)
  end
end

puts "[DEBUG] FastMcp Initializer: Finished setup using mount_in_rails." if debug_mode
