# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Rack middleware: applies GraphMem::McpAccessPolicy (IP allowlist, optional bearer token) to
    # every /mcp path before anything else sees the request.
    class AccessGate
      def initialize(app, policy: nil)
        @app = app
        @policy = policy
      end

      def call(env)
        return @app.call(env) unless Router.mcp_path?(env["PATH_INFO"])

        request = Rack::Request.new(env)
        policy = @policy || OfficialMcp.access_policy
        return error(403, "Forbidden: Remote IP not allowed") unless policy.network_allowed?(request.ip)
        # CORS preflights carry no Authorization header.
        return unauthorized unless env["REQUEST_METHOD"] == "OPTIONS" || policy.authenticated?(request)

        @app.call(env)
      end

      private

      def unauthorized
        status, headers, body = error(401, "Unauthorized: send `Authorization: Bearer <#{GraphMem::McpAccessPolicy::TOKEN_ENV}>`")
        [ status, headers.merge("WWW-Authenticate" => 'Bearer realm="graph_mem"'), body ]
      end

      def error(status, message)
        [ status, { "Content-Type" => "application/json" }, [ JSON.generate(jsonrpc: "2.0", error: { code: -32_600, message: message }) ] ]
      end
    end
  end
end
