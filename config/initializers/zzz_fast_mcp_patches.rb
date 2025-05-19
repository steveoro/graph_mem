# frozen_string_literal: true

# Monkey patches for the fast-mcp gem
# These patches address issues identified during integration.

if defined?(FastMcp::Server) && defined?(FastMcp::Transports::RackTransport)
  Rails.logger.info "[FastMcpPatches] Applying patches to FastMcp gem..."

  # Patch 1: Ensure FastMcp::Server#send_response returns the response hash.
  # This is crucial for RackTransport to receive the data it needs.
  module FastMcp
    class Server
      alias_method :original_send_response, :send_response

      def send_response(response_hash)
        # Call the original method for its side effects (logging, sending via transport)
        original_send_response(response_hash)
        # Ensure the response hash is returned for RackTransport
        response_hash
      end
    end
  end

  # Patch 2: Ensure FastMcp::Transports::RackTransport#process_json_request
  # correctly formats the Rack response body as [JSON_STRING].
  module FastMcp
    module Transports
      class RackTransport
        alias_method :original_process_json_request, :process_json_request

        def process_json_request(request)
          body = request.body.read
          response_data = @server.handle_request(body) # This is a hash or nil

          final_response_body_string = if response_data.nil? || (response_data.is_a?(Hash) && response_data.empty?)
                                         @logger.info("[FastMcpPatches] Response data from server is nil or empty, defaulting to JSON string '[]'")
                                         "[]"
          else
                                         JSON.generate(response_data)
          end

          @logger.info("[FastMcpPatches] Final Rack response body string: #{final_response_body_string}")
          # The Rack body must be an array (or each-able) yielding strings.
          [ 200, { "Content-Type" => "application/json" }, [ final_response_body_string ] ]
        end
      end
    end
  end

  Rails.logger.info "[FastMcpPatches] Successfully applied patches to FastMcp gem."

  # Patch 3: Add detailed logging to FastMcp::Server#handle_tools_call for diagnosing tool lookup issues
  module FastMcp
    class Server
      # Using alias_method to wrap the original handle_tools_call
      alias_method :handle_tools_call_original_for_detailed_logging, :handle_tools_call

      def handle_tools_call(params, id)
        tool_name = params["name"]
        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_ALIAS] Attempting call for tool_name: '#{tool_name}'"

        if @tools.nil?
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_ALIAS] @tools hash is NIL! This should not happen after initialization."
        else
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_ALIAS] Current @tools keys: #{@tools.keys.inspect}"
          retrieved_tool_class = @tools[tool_name]
          if retrieved_tool_class.nil?
            Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_ALIAS] Tool '#{tool_name}' NOT FOUND in @tools using key '#{tool_name}'."
          else
            Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_ALIAS] Tool '#{tool_name}' FOUND. Retrieved: #{retrieved_tool_class.inspect}"
          end
        end

        # Call the original method to continue normal execution (which will produce the 'Tool not found' error if it still occurs)
        handle_tools_call_original_for_detailed_logging(params, id)
      end
    end
  end

  Rails.logger.info "[FastMcpPatches] Successfully applied additional patch for Server#handle_tools_call logging."

else
  Rails.logger.warn "[FastMcpPatches] FastMcp::Server or FastMcp::Transports::RackTransport not defined. Patches not applied."
end
