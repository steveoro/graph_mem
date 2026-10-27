# frozen_string_literal: true

module GraphMem
  # The three MCP allowlists, merged from their two sources: the ENV value (fixed at deploy time)
  # and an additive part stored in AppSettings (Settings › MCP access, UI-2a). This is the only
  # place that knows both; readers use Transports.allowed_hosts / .allowed_origins and
  # OfficialMcp.access_policy, and a change is applied with OfficialMcp.refresh_access!.
  #
  #   McpAccessLists.entries(:hosts)        # => ["synth-lan.test", "lan-box.test"] (ENV first)
  #   McpAccessLists.extra_entries(:ips)    # => ["10.8.0.0/24"] (settings only, unfiltered)
  #   McpAccessLists.validate(:origins, "HTTP://Synth-UI.localhost:3002/")[:entries]
  #   # => ["http://synth-ui.localhost:3002"]
  module McpAccessLists
    # ENV variable of each list.
    KINDS = {
      ips: "GRAPH_MEM_MCP_ALLOWED_IPS",
      hosts: "GRAPH_MEM_MCP_ALLOWED_HOSTS",
      origins: "GRAPH_MEM_MCP_ALLOWED_ORIGINS"
    }.freeze

    # AppSettings key of each list's additive part.
    SETTING_KEYS = {
      ips: "mcp_extra_allowed_ips",
      hosts: "mcp_extra_allowed_hosts",
      origins: "mcp_extra_allowed_origins"
    }.freeze

    @warned = false

    class << self
      # @param kind [Symbol] :ips, :hosts or :origins
      # @param env [#[]] injectable for specs
      # @return [Array<String>] the ENV entries, as written
      def env_entries(kind, env: ENV)
        split(env[KINDS.fetch(kind)])
      end

      # The stored additive entries, read straight from the table (no cache) so every process
      # sees a change. Never raises: boot without a database, or a missing table, reads as none.
      #
      # @param kind [Symbol]
      # @return [Array<String>]
      def extra_entries(kind)
        split(AppSettings.uncached_string(SETTING_KEYS.fetch(kind)))
      rescue StandardError => e
        warn_once("Couldn't read the MCP allowlist settings (#{e.class}); using the ENV values only.")
        []
      end

      # ENV entries, then the additive ones, de-duplicated case-insensitively. Used for hosts and
      # origins; the IP list is resolved by McpAccessPolicy, which re-checks every extra.
      #
      # @param kind [Symbol]
      # @return [Array<String>]
      def entries(kind, env: ENV)
        (env_entries(kind, env: env) + extra_entries(kind)).uniq(&:downcase)
      end

      # Checks and normalizes an additive list before it is saved (see Validator).
      #
      # @param kind [Symbol]
      # @param raw [String, nil] comma- or newline-separated input
      # @return [Hash] `{ entries:, errors:, warnings:, duplicates: }`
      def validate(kind, raw, env: ENV)
        Validator.new(kind, env: env).call(raw)
      end

      # @return [Array<String>] ENV entries of +kind+ that can never match (shown, not refused)
      def env_warnings(kind, env: ENV)
        Validator.env_warnings(kind, env: env)
      end

      # @param raw [String, Array, nil] comma- or newline-separated entries
      # @return [Array<String>] stripped, non-blank entries
      def split(raw)
        Array(raw).flat_map { |part| part.to_s.split(/[,\n]/) }.map(&:strip).reject(&:empty?)
      end

      private

      def warn_once(message)
        return if @warned

        @warned = true
        Rails.logger&.warn("[McpAccessLists] #{message}")
      end
    end
  end
end
