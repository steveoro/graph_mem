# frozen_string_literal: true

# Monkey patches for the fast-mcp gem
# These patches address issues identified during integration.

if defined?(FastMcp::Server) && defined?(FastMcp::Transports::RackTransport)
  Rails.logger.info "[FastMcpPatches] Applying patches to FastMcp gem..."

  # Standard JSON-RPC error codes
  STANDARD_JSON_RPC_ERROR_CODES = {
    ParseError: -32700,
    InvalidRequest: -32600,
    MethodNotFound: -32601,
    InvalidParams: -32602,
    InternalError: -32603
  }.freeze

  MCP_GRAPH_MEM_ERROR_CODES = {
    ResourceNotFound: -32001,
    OperationFailed: -32002,
    InternalServerError: -32003
  }.freeze
  # -----------------------------------------------------------------------------

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
  # -----------------------------------------------------------------------------

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
  # -----------------------------------------------------------------------------

  # Patch 3: Correct FastMcp::Server#handle_tools_call to not call .new on an already instantiated tool
  # and retain detailed logging.
  module FastMcp
    class Server
      def handle_tools_call(params, id)
        STDERR.puts "[PATCH_DEBUG|handle_tools_call_V7_ENTRY] RAW PARAMS: #{params.inspect}, ID: #{id.inspect}"
        STDERR.flush
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Attempting call for tool_name: '#{tool_name}' with arguments: #{arguments.inspect}"

        if @tools.nil?
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V7] @tools hash is NIL!"
          send_error_result("#{STANDARD_JSON_RPC_ERROR_CODES[:InternalError]} Internal server error: tools not initialized", id)
          return
        end

        tool = @tools[tool_name]
        unless tool
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V7] Tool '#{tool_name}' NOT FOUND in @tools."
          send_error_result("#{STANDARD_JSON_RPC_ERROR_CODES[:MethodNotFound]} Tool not found: #{tool_name}", id)
          return
        end

        Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Tool '#{tool_name}' FOUND. Retrieved: #{tool.inspect}"

        begin
          symbolized_args = arguments.transform_keys(&:to_sym)
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Calling tool.call_with_schema_validation!(**#{symbolized_args.inspect})"

          actual_tool_data, tool_metadata = tool.call_with_schema_validation!(**symbolized_args)
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Tool '#{tool_name}' executed successfully."
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Raw Result from tool.call_with_schema_validation! (actual_tool_data): #{actual_tool_data.inspect}"
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Raw Result class: #{actual_tool_data.class}"
          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V7] Metadata: #{tool_metadata.inspect}"

          # V8: Complete restructuring to match what's expected by the Cascade MCP Go client
          # Directly use the raw data without any nesting/manipulating
          # According to memory entry 526073c5, the Cascade client's ToolResponse struct
          # expects an array of Content objects in the "content" field
          response_payload = {
            jsonrpc: "2.0",
            id: id,
            result: {
              content: [
                {
                  type: "json",
                  # Try with raw object instead of JSON string
                  json: actual_tool_data
                }
              ]
            }
          }

          Rails.logger.info "[FastMcpPatches|Server#handle_tools_call_V8] response_payload: #{response_payload.inspect}"

          # Note: response_payload is already defined above

          # DEBUG LOGGING (Updated for V8)
          begin
            File.open("#{Rails.root}/tmp/graph_mem_debug.txt", "a") do |f|
              f.puts "Timestamp: #{Time.now.iso8601(6)}"
              f.puts "Tool: #{tool_name} (V8)" # Updated version marker
              f.puts "Result from tool.call_with_schema_validation! (actual_tool_data): #{actual_tool_data.inspect}"
              f.puts "Actual_tool_data class: #{actual_tool_data.class}"
              f.puts "Response hash before JSON.generate (response_payload): #{response_payload.inspect}"
              f.puts "Response[:result] class: #{response_payload[:result].class if response_payload.key?(:result)}"
              f.puts "Response[:result] itself: #{response_payload[:result].inspect if response_payload.key?(:result)}"
              f.puts "Response[:result][:content][0][:json] class: #{response_payload[:result][:content][0][:json].class if response_payload.key?(:result) && response_payload[:result][:content]&.first&.key?(:json)}"
            end
          rescue => log_e
            Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V8] Failed to write to debug log: #{log_e.message}"
          end
          # END DEBUG LOGGING

          STDERR.puts "[PATCH_DEBUG|handle_tools_call_V8] PRE-SEND: response_payload IS: #{response_payload.inspect}"
          STDERR.flush

          @transport.send_message(response_payload)

        rescue FastMcp::Tool::InvalidArgumentsError => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V6] InvalidArgumentsError for tool '#{tool_name}': #{e.message}"
          send_error_result("#{STANDARD_JSON_RPC_ERROR_CODES[:InvalidParams]} #{e.message}", id)
        rescue McpGraphMemErrors::ResourceNotFound => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V6] ResourceNotFoundError for tool '#{tool_name}': #{e.message}"
          send_error_result("#{MCP_GRAPH_MEM_ERROR_CODES[:ResourceNotFound]} #{e.message}", id)
        rescue McpGraphMemErrors::OperationFailed => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V6] OperationFailedError for tool '#{tool_name}': #{e.message}"
          send_error_result("#{MCP_GRAPH_MEM_ERROR_CODES[:OperationFailed]} #{e.message}", id)
        rescue McpGraphMemErrors::InternalServerError => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V6] McpGraphMemErrors::InternalServerError for tool '#{tool_name}': #{e.message} Backtrace: #{e.backtrace.join("\n")}"
          send_error_result("#{STANDARD_JSON_RPC_ERROR_CODES[:InternalError]} #{e.message}", id)
        rescue StandardError => e
          Rails.logger.error "[FastMcpPatches|Server#handle_tools_call_V6] Unhandled StandardError for tool '#{tool_name}': #{e.class} - #{e.message} Backtrace: #{e.backtrace.join("\n")}"
          send_error_result("#{STANDARD_JSON_RPC_ERROR_CODES[:InternalError]} An unexpected internal server error occurred.", id)
        end
      end
    end
  end
end
# -----------------------------------------------------------------------------

# --- BEGIN DEBUG PATCH for StdioTransport ---
Rails.logger.info "[FastMcpPatches] Applying debug patch to FastMcp::Transports::StdioTransport#send_message"
module FastMcp
  module Transports
    class StdioTransport
      alias_method :original_send_message_for_debug, :send_message

      def send_message(message)
        # Log to STDERR immediately upon entry
        STDERR.puts "[STDIO_PATCH_DEBUG|send_message] ENTERED. Received message (class: #{message.class}): #{message.inspect}"
        STDERR.flush

        # Call the original method
        original_send_message_for_debug(message)

        STDERR.puts "[STDIO_PATCH_DEBUG|send_message] EXITED."
        STDERR.flush
      rescue StandardError => e
        STDERR.puts "[STDIO_PATCH_DEBUG|send_message] ERROR: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        STDERR.flush
        raise # Re-raise the error after logging
      end
    end
  end
end
# --- END DEBUG PATCH for StdioTransport ---
# -----------------------------------------------------------------------------

Rails.logger.info "[FastMcpPatches] Successfully applied all patches to FastMcp gem."
