# frozen_string_literal: true

module GraphMem
  module McpStreamableHttp
    # Validates a Streamable HTTP request before it reaches the server (mcp plan PR-2 §2.2-§2.3b):
    # body size, JSON shape, the JSON-RPC envelope and the MCP-Protocol-Version header.
    # Included by GraphMem::McpStreamableHttpTransport; relies on its instance state.
    module RequestChecks
      DEFAULT_MAX_REQUEST_BYTES = 4 * 1024 * 1024
      NOT_A_MESSAGE = "Bad Request: the request body is not a valid JSON-RPC message"

      # Raised by read_limited_body when the body exceeds @max_request_bytes.
      class PayloadTooLarge < StandardError; end

      private

      # Reads at most @max_request_bytes (+1 to detect overflow), whatever Content-Length says.
      def read_limited_body(request)
        limit = @max_request_bytes
        content_length = request.env["CONTENT_LENGTH"]
        raise PayloadTooLarge if content_length && content_length.to_i > limit

        body = request.body.read(limit + 1) || ""
        raise PayloadTooLarge if body.bytesize > limit

        body
      end

      # @return [Array(Symbol, Object)] [:ok, parsed] or [:error, rack_response]. A tagged return,
      #   so a JSON array sent by the client is never mistaken for an error triplet (§2.3a).
      def parse_json(body)
        [ :ok, JSON.parse(body, symbolize_names: true) ]
      rescue JSON::ParserError, EncodingError # EncodingError: invalid UTF-8 object key (Ruby SDK 1.8.1 #624)
        [ :error, json_rpc_error_response(400, -32_700, "Parse error: Invalid JSON") ]
      end

      # @return [Array, nil] a 400 Rack response when +parsed+ isn't a valid JSON-RPC 2.0 message
      def envelope_error(parsed)
        unless parsed.is_a?(Hash)
          message = parsed.is_a?(Array) ? "Bad Request: JSON-RPC batching is not supported" : NOT_A_MESSAGE
          return json_rpc_error_response(400, -32_600, message)
        end

        id = parsed[:id]
        return json_rpc_error_response(400, -32_600, NOT_A_MESSAGE, id) unless parsed[:jsonrpc] == "2.0"
        if parsed.key?(:id) && id.nil? && !(parsed.key?(:result) || parsed.key?(:error))
          return json_rpc_error_response(400, -32_600, "Invalid Request", data: "Request ID must not be null")
        end
        unless id.nil? || FastMcp::JsonRpc.valid_id?(id)
          return json_rpc_error_response(400, -32_600, "Invalid Request: id must be a string or integer")
        end
        return nil if parsed[:method].nil? || parsed[:method].is_a?(String)

        json_rpc_error_response(400, -32_600, "Invalid Request: method must be a string", id)
      end

      # Any supported handshake version is accepted (it needn't equal the negotiated one); an absent
      # header is accepted for pre-2025-06-18 clients. Checked after the session lookup, so an
      # unknown session is still a 404 first, as in the reference servers.
      #
      # @return [Array, nil] a 400 Rack response for an unsupported MCP-Protocol-Version
      def protocol_version_error(request, request_id = nil)
        header = request.env["HTTP_MCP_PROTOCOL_VERSION"]&.strip
        return nil if header.nil? || header.empty? || @server.supported_protocol_version?(header)

        json_rpc_error_response(
          400, -32_000,
          "Bad Request: Unsupported protocol version: #{header} " \
          "(supported versions: #{@server.protocol_versions.join(', ')})",
          request_id
        )
      end

      def notification_method?(method)
        method.to_s.start_with?("notifications/")
      end
    end
  end
end
