# frozen_string_literal: true

require_relative "../../lib/graph_mem/version"
require "fast_mcp"
require_relative "../../lib/graph_mem/mcp_profile"
require_relative "../../lib/graph_mem/mcp_tool_registry"
require_relative "../../lib/graph_mem/mcp_error_formatter"
require_relative "../../lib/graph_mem/mcp_server_patch"
require_relative "../../lib/graph_mem/mcp_streamable_http_transport"
require_relative "../../lib/graph_mem/mcp_server_options"

# Toggle this to enable/disable debug output
debug_mode = false

# Clear any existing FastMcp server instance if Rails reloads initializers
# This helps prevent issues with stale server instances in development.
if Rails.env.development? && defined?(FastMcp.server) && FastMcp.server
  puts "[DEBUG] FastMcp Initializer: Clearing existing FastMcp.server instance" if debug_mode
  FastMcp.server = nil
end

puts "[DEBUG] FastMcp Initializer: Starting setup..." if debug_mode

# Configure FastMcp logger. Under the stdio runner (GRAPH_MEM_MCP_STDIO=1) stdout carries JSON-RPC,
# so log to stderr there (mcp plan PR-2 §2.13).
fast_mcp_logger = Logger.new(ENV["GRAPH_MEM_MCP_STDIO"] ? $stderr : $stdout)
fast_mcp_logger.level = Logger::DEBUG # Or your preferred level (INFO, WARN, ERROR)

# Per-profile instructions (GraphMem::McpInstructions, mcp plan PR-2 §2.17) and only the
# capabilities graph_mem delivers (§2.18).
server = FastMcp::Server.new(
  name: Rails.application.class.module_parent_name.underscore.dasherize,
  version: GraphMem::VERSION.to_s,
  logger: fast_mcp_logger,
  **GraphMem::McpServerOptions.for_http
)

GraphMem::McpErrorFormatter.install(server)

server.filter_tools do |request, tools|
  profile = GraphMem::McpProfile.from_request(request)
  GraphMem::McpProfile.select_tools(tools, profile)
end

server.filter_prompts do |request, prompts|
  profile = GraphMem::McpProfile.from_request(request)
  GraphMem::McpProfile.select_prompts(prompts, profile)
end

Rails.application.config.after_initialize do
  GraphMem::McpToolRegistry.register_with!(server)
end

# Re-register after code reload so new tool files appear without a full restart.
if Rails.env.development?
  Rails.application.config.to_prepare do
    if FastMcp.server
      GraphMem::McpToolRegistry.register_with!(FastMcp.server)
    end
  end
end

# Who may reach /mcp, and whether they must present a token. Configured via
# GRAPH_MEM_MCP_TOKEN and GRAPH_MEM_MCP_ALLOWED_IPS; see docs/mcp_access_control.md.
mcp_access_policy = GraphMem::McpAccessPolicy.from_env(logger: fast_mcp_logger)
fast_mcp_logger.info("[McpAccessPolicy] /mcp access: #{mcp_access_policy.describe}")

# Mount the combined Streamable HTTP + legacy SSE transport.
#
# `localhost_only: false` is intentional: it disables the inner legacy transport's
# own IP check, which can only compare exact strings. McpStreamableHttpTransport
# applies mcp_access_policy to both endpoints before delegating.
mcp_allowed_origins = [ "localhost", "127.0.0.1", "::1", /\A192\.168\.\d{1,3}\.\d{1,3}\z/, /\A10\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/ ]
Rails.application.config.middleware.use(
  GraphMem::McpStreamableHttpTransport,
  server,
  path_prefix: "/mcp",
  messages_route: "messages",
  sse_route: "sse",
  allowed_origins: mcp_allowed_origins,
  localhost_only: false,
  access_policy: mcp_access_policy,
  # fast-mcp 1.8.0 legacy-SSE options, passed explicitly (mcp plan PR-2 §2.1): a 4 MiB body
  # cap, CORS reflecting only these origins, and a server-issued session id that every
  # /mcp/messages POST must carry (400 without it, 404 for an unknown one).
  max_request_bytes: Integer(ENV.fetch("GRAPH_MEM_MCP_MAX_REQUEST_BYTES", 4 * 1024 * 1024)),
  cors_allowed_origins: mcp_allowed_origins,
  require_sse_session: true
)

FastMcp.server = server

puts "[DEBUG] FastMcp Initializer: Finished setup using GraphMem::McpStreamableHttpTransport." if debug_mode
