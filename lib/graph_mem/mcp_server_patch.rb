# frozen_string_literal: true

# Hides compatibility tools from tools/list.
#
# FastMCP now owns tool dispatch, JSON-safe results, and configurable error
# formatting. This override only preserves GraphMem's hidden-but-callable
# compatibility aliases after FastMCP applies the request profile filter.
module GraphMem
  module McpServerPatch
    EXPECTED_FORK_VERSION = "1.7.1"

    private

    def handle_tools_list(id)
      tools = visible_tools(current_request).filter_map do |tool|
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

if defined?(FastMcp::Server) &&
   FastMcp::Server.ancestors.none? { |m| m.name == "GraphMem::McpServerPatch" }
  unless FastMcp::Server.private_method_defined?(:handle_tools_list) &&
         FastMcp::Server.instance_method(:handle_tools_list).parameters == [ [ :req, :id ] ]
    raise "FastMcp::Server#handle_tools_list signature changed — " \
          "re-sync GraphMem::McpServerPatch against steveoro/fast-mcp"
  end

  FastMcp::Server.prepend(GraphMem::McpServerPatch)
end
