# frozen_string_literal: true

# Patches FastMcp::Server:
# - hide compatibility tools from tools/list
# - emit structured ToolError JSON on tools/call failures (no Ruby backtraces)
module GraphMem
  module McpServerPatch
    def handle_tools_list(id)
      tools = @tools.values.filter_map do |tool|
        next if tool.respond_to?(:mcp_advertised?) && !tool.mcp_advertised?

        tool_info = {
          name: tool.tool_name,
          description: tool.description || "",
          inputSchema: tool.input_schema_to_json || { type: "object", properties: {}, required: [] }
        }
        output_schema = tool.output_schema_to_json
        tool_info[:outputSchema] = output_schema if output_schema
        annotations = tool.annotations
        if annotations.any?
          tool_info[:annotations] = annotations.to_h do |key, value|
            camel_key = key.to_s.gsub(/_([a-z])/) { ::Regexp.last_match(1).upcase }.to_sym
            [ camel_key, value ]
          end
        end
        tool_info
      end

      send_result({ tools: tools }, id)
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
        send_formatted_result(result, id, metadata, tool: tool)
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
