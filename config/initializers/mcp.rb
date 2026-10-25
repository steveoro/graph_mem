# frozen_string_literal: true

# MCP over Streamable HTTP, served by the official MCP Ruby SDK (`mcp` gem); see
# docs/plans/mg-streamlined-plan.md and docs/mcp_access_control.md.
#
#   /mcp              default profile (12 tools)
#   /mcp/readonly     context and read tools (9)
#   /mcp/maintenance  every tool (22)
#
# Request order for /mcp paths: the access policy (IP allowlist, optional bearer token), then
# the request context (X-MCP-Client, profile, session id for the tools), then that profile's
# transport. Each transport is built on first use from GRAPH_MEM_MCP_MAX_SESSIONS,
# GRAPH_MEM_MCP_MAX_REQUEST_BYTES, GRAPH_MEM_MCP_ALLOWED_HOSTS and GRAPH_MEM_MCP_ALLOWED_ORIGINS,
# with the gem's DNS-rebinding protection (Host and Origin checks) on.
require_relative "../../lib/graph_mem/version"
require_relative "../../lib/graph_mem/mcp_profile"
require_relative "../../lib/graph_mem/mcp_access_policy"
require_relative "../../lib/graph_mem/official_mcp"
require_relative "../../lib/graph_mem/official_mcp/access_gate"
require_relative "../../lib/graph_mem/official_mcp/request_context"
require_relative "../../lib/graph_mem/official_mcp/router"

# Transport-level failures (e.g. a stdio frame the gem couldn't handle) use the global configuration.
MCP.configure { |config| config.exception_reporter = GraphMem::OfficialMcp::EXCEPTION_REPORTER }

Rails.application.config.middleware.use(GraphMem::OfficialMcp::AccessGate)
Rails.application.config.middleware.use(GraphMem::OfficialMcp::RequestContext)
Rails.application.config.middleware.use(GraphMem::OfficialMcp::Router)

Rails.application.config.after_initialize do
  Rails.logger.info("[McpAccessPolicy] /mcp access: #{GraphMem::OfficialMcp.access_policy.describe}") unless ENV["GRAPH_MEM_MCP_STDIO"]
end

# Rebuild the servers after a code reload so changed tool classes are served.
Rails.application.reloader.to_prepare { GraphMem::OfficialMcp::Transports.reset! } if Rails.env.development?
