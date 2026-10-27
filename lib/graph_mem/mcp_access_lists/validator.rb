# frozen_string_literal: true

require "ipaddr"

module GraphMem
  module McpAccessLists
    # Checks and normalizes the additive part of one MCP allowlist before it is saved (UI-2a A2).
    # The rules match ENV's, stricter where the UI can refuse: anything ENV would only warn about
    # (an unparseable entry) is an error here, and `any`/`all`/`*` are always refused, since
    # lifting the IP restriction is a deployment decision the additive model can't express.
    #
    #   Validator.new(:hosts).call("Synth-LAN.test, localhost")
    #   # => { entries: ["synth-lan.test"], errors: [], duplicates: [],
    #   #      warnings: ["localhost: loopback names are always accepted"] }
    class Validator
      UNRESTRICTED = McpAccessPolicy::UNRESTRICTED
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
      DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze
      HOST_LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
      IPV4 = /\A\d{1,3}(?:\.\d{1,3}){3}\z/
      PUBLIC_RANGE_WARNING = "public range: reachable from outside your network, protected only by the bearer token. " \
                             "If the token is removed, this entry stops applying."

      class << self
        # ENV entries that can never match (an origin with a path or trailing slash, a host with a
        # scheme or path). ENV keeps working as before; the panel only flags them.
        #
        # @return [Array<String>]
        def env_warnings(kind, env: ENV)
          McpAccessLists.env_entries(kind, env: env).filter_map do |entry|
            case kind
            when :hosts then "#{entry}: a host has no scheme or path, so it never matches" if entry.match?(%r{://|/})
            when :origins then "#{entry}: an origin is scheme://host[:port] only, so it never matches" unless entry.match?(%r{\Ahttps?://[^/?#@\s]+\z}i)
            end
          end
        end

        # Whether an IP entry lies outside the loopback and private ranges.
        #
        # @param entry [String]
        # @return [Boolean] false for an unparseable entry
        def public_ip?(entry)
          !McpAccessPolicy.within_defaults?(IPAddr.new(entry))
        rescue IPAddr::Error
          false
        end
      end

      # @param kind [Symbol] :ips, :hosts or :origins
      # @param env [#[]] injectable for specs
      def initialize(kind, env: ENV)
        @kind = McpAccessLists::KINDS.key?(kind) ? kind : raise(ArgumentError, "unknown MCP allowlist: #{kind.inspect}")
        @env = env
      end

      # @param raw [String, nil] comma- or newline-separated input
      # @return [Hash] `entries:` the normalized entries to store; `errors:` one message per refused
      #   entry (any error means nothing is saved); `warnings:`; `duplicates:` entries already in ENV
      def call(raw)
        @entries = []
        @errors = []
        @warnings = []
        @duplicates = []
        McpAccessLists.split(raw).each { |entry| send(:"check_#{@kind.to_s.delete_suffix('s')}", entry) }
        { entries: @entries.uniq, errors: @errors, warnings: @warnings, duplicates: @duplicates.uniq }
      end

      private

      def check_ip(entry)
        return error(entry, "can't be added here: lifting the IP restriction is an ENV decision (with GRAPH_MEM_MCP_TOKEN)") if UNRESTRICTED.include?(entry.downcase)

        range = parse_ip(entry)
        return error(entry, "isn't an IP address or a CIDR range") unless range

        masked = entry.include?("/") && parse_ip(entry.split("/").first).to_s != range.to_s
        # Client addresses are matched in native IPv4 form, so a mapped entry would never match.
        range = range.native if range.ipv4_mapped?
        return error(entry, "can't be added here: a /0 lifts the IP restriction, which is an ENV decision (with GRAPH_MEM_MCP_TOKEN)") if range.prefix.zero?

        text = ip_text(range)
        if masked
          warn(entry, "host bits masked, saved as #{text}")
        elsif text != entry.downcase
          warn(entry, "saved as #{text}")
        end
        return duplicate(text) if env_ranges.any? { |known| same_range?(known, range) }

        if McpAccessPolicy.within_defaults?(range)
          warn(text, "already covered by the ENV or default ranges, so it has no effect") if covered_by_env?(range)
        elsif env_policy.token_required?
          warn(text, PUBLIC_RANGE_WARNING)
        else
          return error(text, "is a public range: it needs GRAPH_MEM_MCP_TOKEN, as in ENV")
        end
        @entries << text
      end

      def check_host(entry)
        value = entry.downcase
        return error(entry, "wildcards and any/all aren't accepted; list each host") if value.include?("*") || %w[any all].include?(value)
        return error(entry, "is a URL; enter the host name only, without a scheme") if value.include?("://")
        return error(entry, "may not contain a path, user info or spaces") if value.match?(%r{[/@?#\s]})

        host = parse_authority(value, bare_ipv6: true)
        return error(entry, "isn't a host name, an IPv4 address or a bracketed IPv6 address, with an optional :port") unless host
        return warn(entry, "loopback names are always accepted") if LOOPBACK_HOSTS.include?(host[:name])

        # The gem compares a request's bare host name or its full host:port, so an IPv6 address
        # without a port is stored unbracketed to match on any port.
        name = host[:ipv6] && host[:port] ? "[#{host[:name]}]" : host[:name]
        add_unless_in_env(:hosts, host[:port] ? "#{name}:#{host[:port]}" : name)
      end

      def check_origin(entry)
        value = entry.downcase
        return error(entry, "isn't an origin; list each scheme://host[:port]") if %w[* null].include?(value)

        scheme, rest = value.match(%r{\A([a-z][a-z0-9+.-]*)://(.*)\z})&.captures
        return error(entry, "must look like http://host[:port]") unless scheme
        return error(entry, "only http and https origins are possible") unless DEFAULT_PORTS.key?(scheme)

        if rest.end_with?("/")
          rest = rest.delete_suffix("/")
          warn(entry, "trailing / removed (browsers never send it)")
        end
        return error(entry, "an origin has no path, query, fragment or user info") if rest.match?(%r{[/?#@\s]})

        host = parse_authority(rest, bare_ipv6: false)
        return error(entry, "isn't a valid http(s)://host[:port] origin") unless host

        port = host[:port]
        if port == DEFAULT_PORTS[scheme]
          port = nil
          warn(entry, "default port removed (browsers never send it)")
        end
        name = host[:ipv6] ? "[#{host[:name]}]" : host[:name]
        add_unless_in_env(:origins, "#{scheme}://#{name}#{":#{port}" if port}")
      end

      # @return [Hash, nil] `{ name:, port:, ipv6: }`
      def parse_authority(value, bare_ipv6:)
        if (match = value.match(/\A\[([0-9a-f:.]+)\](?::(\d{1,5}))?\z/))
          name, port = match.captures
          return nil unless ipv6?(name)

          ipv6 = true
        elsif bare_ipv6 && value.count(":") > 1
          return nil unless ipv6?(value)

          name = value
          ipv6 = true
        elsif (match = value.match(/\A([a-z0-9.-]+)(?::(\d{1,5}))?\z/))
          name, port = match.captures
          return nil unless valid_host_name?(name)
        else
          return nil
        end

        port = port&.to_i
        return nil if port && !port.between?(1, 65_535)

        { name: name, port: port, ipv6: ipv6 || false }
      end

      def valid_host_name?(name)
        return parse_ip(name)&.ipv4? || false if name.match?(IPV4)

        name.length <= 253 && name.split(".", -1).all? { |label| label.match?(HOST_LABEL) }
      end

      def ipv6?(value)
        parse_ip(value)&.ipv6? || false
      end

      def add_unless_in_env(kind, text)
        return duplicate(text) if McpAccessLists.env_entries(kind, env: @env).any? { |known| known.casecmp?(text) }

        @entries << text
      end

      def parse_ip(value)
        IPAddr.new(value)
      rescue IPAddr::Error
        nil
      end

      def ip_text(range)
        full = range.ipv4? ? 32 : 128
        range.prefix == full ? range.to_s : "#{range}/#{range.prefix}"
      end

      def same_range?(left, right)
        left.family == right.family && left.to_s == right.to_s && left.prefix == right.prefix
      end

      def covered_by_env?(range)
        env_policy.network_unrestricted? ||
          env_policy.allowed_ips.any? { |known| known.family == range.family && known.include?(range) }
      end

      # The ENV part alone, resolved exactly as at boot (defaults when unset).
      def env_policy
        @env_policy ||= McpAccessPolicy.new(token: @env[McpAccessPolicy::TOKEN_ENV], allowed_ips: @env[McpAccessPolicy::ALLOWED_IPS_ENV])
      end

      def env_ranges
        @env_ranges ||= McpAccessLists.env_entries(:ips, env: @env).filter_map { |entry| parse_ip(entry) }
      end

      def error(entry, message)
        @errors << "#{entry}: #{message}"
        nil
      end

      def warn(entry, message)
        @warnings << "#{entry}: #{message}"
        nil
      end

      def duplicate(text)
        @duplicates << text
        nil
      end
    end
  end
end
