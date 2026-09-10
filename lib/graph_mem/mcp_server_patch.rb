# frozen_string_literal: true

# Patches FastMcp::Server:
# - route per-request responses through the transport handling the request
# - emit structured ToolError JSON on tools/call failures (no Ruby backtraces)
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

    def handle_tools_call(params, headers, id)
      tool_name = params["name"] || params[:name]
      arguments = params["arguments"] || params[:arguments] || {}

      return send_error(-32_602, "Invalid params: missing tool name", id) unless tool_name

      tool = @tools[tool_name]
      return send_error(-32_602, "Tool not found: #{tool_name}", id) unless tool

      begin
        symbolized_args = symbolize_keys(arguments)

        tool_instance = tool.new(headers: headers)
        authorized = tool_instance.authorized?(**symbolized_args)

        unless authorized
          @logger.error("Unauthorized tool call: #{tool_name}")
          return send_error_result(ToolError.dump_unauthorized(tool_name: tool_name), id)
        end

        result, metadata = tool_instance.call_with_schema_validation!(**symbolized_args)
        send_formatted_result(result, id, metadata)
      rescue StandardError => e
        @logger.error("Error calling tool #{tool_name}: #{e.class}: #{e.message}")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
        send_error_result(ToolError.dump(e, tool_name: tool_name), id)
      end
    end

    def send_error_result(message, id)
      @on_error_result&.call(message)

      error_result = {
        content: [ { type: "text", text: message } ],
        isError: true
      }

      send_result(error_result, id)
    end
  end
end

FastMcp::Server.prepend(GraphMem::McpServerPatch) if defined?(FastMcp::Server)
