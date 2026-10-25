# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Rack middleware (after the access check): carries what a tool needs from the HTTP request
    # (X-MCP-Client, the profile, the Mcp-Session-Id) to the gem's handlers.
    #
    # The gem forwards only env["mcp.auth_info"] to handlers (as server_context[:auth_info], also on
    # the SSE body's thread), and its transport reads issuer/subject/client_id from it to bind
    # sessions, so it must be an MCP::Server::OAuth::AccessToken. The context rides in its claims;
    # the token's own client_id and subject stay nil, so sessions are not bound to a client.
    class RequestContext
      ENV_KEY = "mcp.auth_info"
      CLAIM = :graph_mem

      # The per-request values.
      Context = Data.define(:client_id, :profile, :session_id) do
        # Headers in the shape ApplicationTool#current_client_id reads.
        #
        # @return [Hash{String => String}]
        def headers
          client_id.present? ? { ApplicationTool::MCP_CLIENT_HEADER => client_id } : {}
        end

        # Runs the block with the thread-locals ApplicationTool reads for the profile and session.
        def around_call
          saved = [ Thread.current[:graph_mem_mcp_profile], Thread.current[:graph_mem_mcp_session_id] ]
          Thread.current[:graph_mem_mcp_profile] = profile
          Thread.current[:graph_mem_mcp_session_id] = session_id
          yield
        ensure
          Thread.current[:graph_mem_mcp_profile], Thread.current[:graph_mem_mcp_session_id] = saved
        end
      end

      # @param server_context [Hash, MCP::ServerContext, nil] what the gem hands a tool
      # @return [Context] the request's context, or one from the process env (stdio)
      def self.from_server_context(server_context)
        token = server_context.respond_to?(:[]) ? server_context[:auth_info] : nil
        carried = token.respond_to?(:claims) ? token.claims[CLAIM] : nil
        carried.is_a?(Context) ? carried : Context.new(client_id: nil, profile: GraphMem::McpProfile.from_env, session_id: nil)
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        profile = Router.profile_for(env["PATH_INFO"])
        if profile
          context = Context.new(client_id: env["HTTP_X_MCP_CLIENT"].presence, profile: profile, session_id: env["HTTP_MCP_SESSION_ID"].presence)
          env[ENV_KEY] = MCP::Server::OAuth::AccessToken.new(token: "graph_mem", claims: { CLAIM => context })
        end
        @app.call(env)
      end
    end
  end
end
