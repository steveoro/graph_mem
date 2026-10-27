# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # One Streamable HTTP transport per profile, built on first use from the current settings.
    module Transports
      @mutex = Mutex.new
      @transports = {}
      @access_lists = nil
      @built_without_settings = false

      class << self
        # @param profile [Symbol]
        # @return [MCP::Server::Transports::StreamableHTTPTransport]
        def for(profile)
          rebuild_after_failed_read if @built_without_settings
          @mutex.synchronize { @transports[profile] ||= build(profile) }
        end

        # Closes every transport (sessions included) and drops the allowlist snapshot; the next
        # request builds them again from the current settings. Called by OfficialMcp.refresh_access!
        # for a hosts or origins change, on code reload in development, and by specs.
        def reset!
          closing = @mutex.synchronize do
            @access_lists = nil
            @built_without_settings = false
            @transports.values.tap { @transports = {} }
          end
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
            allowed_hosts: allowed_hosts,
            allowed_origins: allowed_origins
          }
        end

        # The `Host` values accepted on /mcp besides the loopback names: GRAPH_MEM_MCP_ALLOWED_HOSTS
        # plus the Settings › MCP access additions (McpAccessLists), from {access_lists}.
        #
        # @return [Array<String>]
        def allowed_hosts
          access_lists[:hosts]
        end

        # The browser origins allowed on /mcp besides same-origin pages: GRAPH_MEM_MCP_ALLOWED_ORIGINS
        # plus the Settings › MCP access additions (McpAccessLists), exact `scheme://host:port` values.
        # The one source for both the transport's Origin check (when a transport is built) and /mcp
        # CORS (config/initializers/cors.rb, per request), through the same {access_lists} snapshot.
        #
        # @return [Array<String>] the configured origins, as written
        def allowed_origins
          access_lists[:origins]
        end

        # The allowed hosts and origins, read together and kept until {reset!}, so the transports and
        # /mcp CORS share one snapshot and CORS costs no settings query per request. A runtime change
        # goes through OfficialMcp.refresh_access!(transports: true). When the settings can't be read
        # the ENV entries are returned and nothing is kept, so the next call reads them again.
        #
        # @return [Hash{Symbol => Array<String>}] `{ hosts:, origins: }`
        def access_lists
          @access_lists ||= { hosts: McpAccessLists.entries!(:hosts).freeze, origins: McpAccessLists.entries!(:origins).freeze }.freeze
        rescue McpAccessLists::ReadError
          { hosts: McpAccessLists.env_entries(:hosts), origins: McpAccessLists.env_entries(:origins) }
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
          transport = MCP::Server::Transports::StreamableHTTPTransport.new(ServerFactory.for(profile), **options)
          @built_without_settings = true if @access_lists.nil?
          transport
        end

        # A transport built while the settings couldn't be read lacks their hosts and origins. Once
        # they can be read again, rebuild (its sessions close, as on any hosts or origins change).
        def rebuild_after_failed_read
          access_lists
          reset! unless @access_lists.nil?
        end
      end
    end
  end
end
