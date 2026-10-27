# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # One Streamable HTTP transport per profile, built on first use from the current settings.
    module Transports
      @mutex = Mutex.new
      @transports = {}

      class << self
        # @param profile [Symbol]
        # @return [MCP::Server::Transports::StreamableHTTPTransport]
        def for(profile)
          @mutex.synchronize { @transports[profile] ||= build(profile) }
        end

        # Closes every transport (sessions included); the next request builds them again from the
        # current settings. Used on code reload in development and by specs.
        def reset!
          closing = @mutex.synchronize { @transports.values.tap { @transports = {} } }
          closing.each(&:close)
        end

        # Transport options from the environment (D2, D4, D6, D7). DNS-rebinding protection (Host
        # and Origin checks) stays at the gem's default: on.
        #
        # @return [Hash]
        def options
          {
            enable_json_response: true,
            max_sessions: Integer(ENV.fetch("GRAPH_MEM_MCP_MAX_SESSIONS", 256)),
            max_request_bytes: OfficialMcp.max_request_bytes,
            allowed_hosts: list(ENV["GRAPH_MEM_MCP_ALLOWED_HOSTS"]),
            allowed_origins: allowed_origins
          }
        end

        # The browser origins allowed on /mcp besides same-origin pages: GRAPH_MEM_MCP_ALLOWED_ORIGINS,
        # exact `scheme://host:port` values. The one source for both the transport's Origin check (read
        # once, when a transport is built) and /mcp CORS (config/initializers/cors.rb, read per request):
        # a source that changes at runtime must also call {reset!}, or the two disagree until it does.
        #
        # @return [Array<String>] the configured origins, as written
        def allowed_origins
          list(ENV["GRAPH_MEM_MCP_ALLOWED_ORIGINS"])
        end

        # Whether +origin+ is in {allowed_origins}, compared case-insensitively as the transport does.
        #
        # @param origin [String, nil] a request's `Origin` header
        # @return [Boolean]
        def allowed_origin?(origin)
          return false if origin.nil?

          allowed_origins.any? { |allowed| allowed.casecmp?(origin) }
        end

        private

        def build(profile)
          MCP::Server::Transports::StreamableHTTPTransport.new(ServerFactory.for(profile), **options)
        end

        def list(raw)
          raw.to_s.split(",").map(&:strip).reject(&:empty?)
        end
      end
    end
  end
end
