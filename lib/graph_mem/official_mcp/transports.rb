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
            allowed_origins: list(ENV["GRAPH_MEM_MCP_ALLOWED_ORIGINS"])
          }
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
