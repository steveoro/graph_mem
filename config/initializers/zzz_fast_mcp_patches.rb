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

  # Patch 3: Correct FastMcp::Server#handle_tools_call to not call .new on an already instantiated tool
  # and retain detailed logging.
  module FastMcp
    class Server
      # We are completely overriding the original handle_tools_call method here.
      # The original alias handle_tools_call_original_for_detailed_logging might not be needed
      # unless we intend to call the gem's version for some reason.
      # For this fix, we directly implement the corrected logic.

      # Remove the old alias for clarity if it's no longer used or redefine if necessary.
      # For now, let's assume the override is sufficient.
      # If `alias_method :handle_tools_call_original_for_detailed_logging, :handle_tools_call` was here,
      # it would now alias our new method if not removed or handled carefully.

      def handle_tools_call(params, id)
        tool_name = params["name"] # Use string key as per original method
        arguments = params["arguments"] || {}

        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_FIXED] Attempting call for tool_name: '#{tool_name}' with arguments: #{arguments.inspect}"

        if @tools.nil?
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_FIXED] @tools hash is NIL!"
          return send_error(-32_000, "Internal server error: tools not initialized", id)
        end

        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_FIXED] Current @tools keys: #{@tools.keys.inspect}"
        tool = @tools[tool_name]

        unless tool
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_FIXED] Tool '#{tool_name}' NOT FOUND in @tools."
          return send_error(-32_602, "Tool not found: #{tool_name}", id)
        end

        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_FIXED] Tool '#{tool_name}' FOUND. Retrieved: #{tool.inspect}"

        begin
          symbolized_args = arguments.transform_keys(&:to_sym) # Symbolize keys for Ruby kwargs
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_FIXED] Calling tool.call_with_schema_validation!(**#{symbolized_args.inspect})"

          # --- THIS IS THE CRITICAL FIX ---
          result, metadata = tool.call_with_schema_validation!(**symbolized_args)
          # --- END CRITICAL FIX ---

          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_FIXED] Tool '#{tool_name}' executed successfully. Result: #{result.inspect}, Metadata: #{metadata.inspect}"
          send_formatted_result(result, id, metadata)
        rescue FastMcp::Tool::InvalidArgumentsError => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_FIXED] Invalid arguments for tool #{tool_name}: #{e.message}"
          send_error_result(e.message, id) # Assuming send_error_result is a method in FastMcp::Server
        rescue StandardError => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_FIXED] Error calling tool #{tool_name}: #{e.message} Backtrace: #{e.backtrace.join("\n")}"
          send_error_result("#{e.message}, #{e.backtrace.join("\n")}", id) # Assuming send_error_result is a method
        end
      end
    end
  end

  Rails.logger.info "[FastMcpPatches] Successfully applied FIX for Server#handle_tools_call and retained logging."

else
  Rails.logger.warn "[FastMcpPatches] FastMcp::Server or FastMcp::Transports::RackTransport not defined. Patches not applied."
end
