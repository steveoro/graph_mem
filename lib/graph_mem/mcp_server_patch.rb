# frozen_string_literal: true

# Small, public-method patch to FastMcp::Server#send_response so per-request
# responses can be routed through the transport currently handling the request,
# instead of relying on a shared @transport ivar that would race between the
# Streamable HTTP and legacy SSE transports.
module GraphMem
  module McpServerPatch
    def send_response(response)
      transport = Thread.current[:graph_mem_mcp_transport] || @transport

      if transport
        @logger.debug("Sending response: #{response.inspect}")
        transport.send_message(response)
      else
        @logger.warn("No transport available to send response: #{response.inspect}")
      end
    end
  end
end

FastMcp::Server.prepend(GraphMem::McpServerPatch) if defined?(FastMcp::Server)
