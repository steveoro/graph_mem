# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Rack middleware: sends /mcp, /mcp/readonly and /mcp/maintenance to that profile's
    # Streamable HTTP transport; any other /mcp/* path is 404 (the legacy /mcp/sse is gone).
    class Router
      PREFIX = "/mcp"
      PROFILE_PATHS = {
        "/mcp" => :default, "/mcp/" => :default,
        "/mcp/readonly" => :readonly, "/mcp/readonly/" => :readonly,
        "/mcp/maintenance" => :maintenance, "/mcp/maintenance/" => :maintenance
      }.freeze

      # @param path [String, nil]
      # @return [Boolean] whether the path belongs to the MCP endpoint
      def self.mcp_path?(path)
        path == PREFIX || path.to_s.start_with?("#{PREFIX}/")
      end

      # @param path [String, nil]
      # @return [Symbol, nil] the profile served on that path
      def self.profile_for(path)
        PROFILE_PATHS[path]
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless self.class.mcp_path?(env["PATH_INFO"])

        profile = self.class.profile_for(env["PATH_INFO"])
        return [ 404, { "Content-Type" => "application/json" }, [ JSON.generate(jsonrpc: "2.0", error: { code: -32_601, message: "Endpoint not found" }) ] ] unless profile

        Transports.for(profile).call(env)
      end
    end
  end
end
