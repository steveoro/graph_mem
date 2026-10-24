# frozen_string_literal: true

module GraphMem
  # Access-Control-Allow-Origin is not a constant: it is set per response from the validated Origin
  # (mcp plan PR-2 §2.9). Helpers of GraphMem::McpStreamableHttpTransport, split out to keep each file small.
  module McpStreamableHttp
    SSE_HEADERS = {
      "Content-Type" => "text/event-stream",
      "Cache-Control" => "no-cache, no-store, must-revalidate",
      "Connection" => "keep-alive",
      "X-Accel-Buffering" => "no",
      "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Authorization, Content-Type, Mcp-Session-Id, MCP-Protocol-Version, X-MCP-Client",
      "Access-Control-Expose-Headers" => "Mcp-Session-Id, MCP-Protocol-Version",
      "Access-Control-Max-Age" => "86400",
      "Keep-Alive" => "timeout=600",
      "Pragma" => "no-cache",
      "Expires" => "0"
    }.freeze

    CORS_HEADERS = {
      "access-control-allow-methods" => "GET, POST, DELETE, OPTIONS",
      "access-control-allow-headers" => "Authorization, Content-Type, Mcp-Session-Id, MCP-Protocol-Version, X-MCP-Client",
      "access-control-expose-headers" => "Mcp-Session-Id, MCP-Protocol-Version",
      "access-control-max-age" => "86400",
      "Content-Type" => "text/plain"
    }.freeze
  end
end
