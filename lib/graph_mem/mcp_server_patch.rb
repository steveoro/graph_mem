# frozen_string_literal: true

# Hides compatibility tools from tools/list.
#
# FastMCP now owns tool dispatch, JSON-safe results, and configurable error
# formatting. These filtering shims remain until filtering can hide tools
# without creating server copies that mutate each tool class's server pointer.
module GraphMem
  module McpServerPatch
    def create_filtered_copy(request)
      super.tap { |filtered_server| GraphMem::McpErrorFormatter.install(filtered_server) }
    end

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
  end
end

FastMcp::Server.prepend(GraphMem::McpServerPatch) if defined?(FastMcp::Server)
