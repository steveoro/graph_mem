# frozen_string_literal: true

module GraphMem
  # Helpers of GraphMem::McpStreamableHttpTransport, split out to keep each file small.
  module McpStreamableHttp
    SSE_HEADERS = {
      "Content-Type" => "text/event-stream",
      "Cache-Control" => "no-cache, no-store, must-revalidate",
      "Connection" => "keep-alive",
      "X-Accel-Buffering" => "no",
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Authorization, Content-Type, Mcp-Session-Id, X-MCP-Client",
      "Access-Control-Expose-Headers" => "Mcp-Session-Id",
      "Access-Control-Max-Age" => "86400",
      "Keep-Alive" => "timeout=600",
      "Pragma" => "no-cache",
      "Expires" => "0"
    }.freeze

    CORS_HEADERS = {
      "access-control-allow-origin" => "*",
      "access-control-allow-methods" => "GET, POST, DELETE, OPTIONS",
      "access-control-allow-headers" => "Authorization, Content-Type, Mcp-Session-Id, X-MCP-Client",
      "access-control-expose-headers" => "Mcp-Session-Id",
      "access-control-max-age" => "86400",
      "Content-Type" => "text/plain"
    }.freeze
  end
end
