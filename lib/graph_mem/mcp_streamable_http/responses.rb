# frozen_string_literal: true

module GraphMem
  module McpStreamableHttp
    # JSON-RPC/HTTP responses, CORS headers and the network/origin checks of the Streamable HTTP transport.
    # Included by GraphMem::McpStreamableHttpTransport; relies on its instance state.
    module Responses
      private

      def message_to_json(message)
        message.is_a?(String) ? message : JSON.generate(message)
      end

      # §2.9: Access-Control-Allow-Origin reflects the request's Origin, and only once
      # validate_origin accepted it; never "*". Always Vary: Origin.
      def cors_headers
        CORS_HEADERS.merge(cors_origin_headers(Thread.current[:graph_mem_mcp_cors_origin]))
      end

      def cors_origin_headers(origin, sse: false)
        allow, vary = sse ? %w[Access-Control-Allow-Origin Vary] : %w[access-control-allow-origin vary]
        origin ? { allow => origin, vary => "Origin" } : { vary => "Origin" }
      end

      def json_response_headers(session_id = nil)
        headers = cors_headers.merge("Content-Type" => "application/json")
        headers["Mcp-Session-Id"] = session_id if session_id
        headers
      end

      # Network reach is decided by McpAccessPolicy, which understands CIDR ranges
      # and guarantees the allowlist stays narrow while no token is configured.
      #
      # Note for proxied deployments: Rack derives request.ip from X-Forwarded-For,
      # which a client can set. Behind a reverse proxy the token, not this check,
      # is the real control.
      def valid_client_ip?(request)
        return true if @access_policy.network_allowed?(request.ip)

        @logger.warn("Blocked connection from disallowed IP: #{request.ip}")
        false
      end

      def validate_origin(request, env)
        origin = env["HTTP_ORIGIN"]
        origin = env["HTTP_REFERER"] || request.host if origin.nil? || origin.empty?

        hostname = extract_hostname(origin)
        return true if hostname.nil? || allowed_origins.empty?

        allowed = allowed_origins.any? do |allowed_origin|
          if allowed_origin.is_a?(Regexp)
            hostname.match?(allowed_origin)
          else
            hostname == allowed_origin
          end
        end

        unless allowed
          @logger.warn("Blocked request with origin: #{hostname}")
          return false
        end

        true
      end

      def extract_hostname(url)
        return nil if url.nil? || url.empty?

        begin
          has_scheme = url.match?(%r{^[a-zA-Z][a-zA-Z0-9+.-]*://})
          parsing_url = has_scheme ? url : "http://#{url}"

          uri = URI.parse(parsing_url)
          return nil if uri.host.nil? || uri.host.empty?

          uri.host
        rescue URI::InvalidURIError
          url.split(":").first if url.match?(%r{^([^:/]+)(:\d+)?$})
        end
      end

      def forbidden_response(message)
        json_rpc_error_response(403, -32_600, message)
      end

      def unauthorized_response
        @logger.warn("Rejected MCP request without a valid bearer token")
        status, headers, body = json_rpc_error_response(
          401, -32_600,
          "Unauthorized: send `Authorization: Bearer <#{GraphMem::McpAccessPolicy::TOKEN_ENV}>`"
        )
        [ status, headers.merge("WWW-Authenticate" => 'Bearer realm="graph_mem"'), body ]
      end

      def endpoint_not_found_response
        json_rpc_error_response(404, -32_601, "Endpoint not found")
      end

      def method_not_allowed_response
        json_rpc_error_response(405, -32_601, "Method not allowed")
      end

      # §2.19 (D-17): the id member is echoed only for an Integer or a validly encoded String id,
      # through the same rule as fast-mcp 1.8.0 (FastMcp::JsonRpc).
      def json_rpc_error_response(http_status, code, message, id = nil, data: nil)
        [ http_status, json_response_headers,
          [ JSON.generate(FastMcp::JsonRpc.error_response(code, message, id, data: data)) ] ]
      end
    end
  end
end
