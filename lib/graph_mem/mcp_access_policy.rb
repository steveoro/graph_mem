# frozen_string_literal: true

require "ipaddr"

module GraphMem
  # Resolves the access posture of the MCP endpoint: which client IPs may connect,
  # and whether a shared bearer token is required.
  #
  # GraphMem stores one graph for one implicit owner, shared by a handful of that
  # owner's agents. There is no per-user authorization model and deliberately so —
  # the shared graph is the point. The available controls are therefore network
  # reach and one shared secret.
  #
  # The policy enforces that at least one of those two is narrow: a request can
  # only come from outside the loopback and private ranges when a token is
  # configured. An instance can never be simultaneously unauthenticated and
  # reachable from a public address, whatever the configuration says.
  class McpAccessPolicy
    TOKEN_ENV = "GRAPH_MEM_MCP_TOKEN"
    ALLOWED_IPS_ENV = "GRAPH_MEM_MCP_ALLOWED_IPS"

    # Sentinel accepted by ALLOWED_IPS_ENV to lift the network restriction.
    # Only honoured when a token is configured.
    UNRESTRICTED = %w[any all *].freeze

    LOOPBACK_RANGES = %w[127.0.0.0/8 ::1].freeze
    PRIVATE_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10].freeze
    DEFAULT_RANGES = (LOOPBACK_RANGES + PRIVATE_RANGES).freeze

    BEARER_PREFIX = /\ABearer\s+/i

    attr_reader :token, :allowed_ips

    class << self
      # Builds the policy from the environment. `env` is injectable for specs.
      def from_env(env: ENV, logger: nil)
        token = env[TOKEN_ENV].to_s.strip.presence
        new(token: token, allowed_ips: env[ALLOWED_IPS_ENV], logger: logger)
      end
    end

    # @param token [String, nil] shared secret; when nil no token is required
    # @param allowed_ips [String, Array, nil] comma-separated list, array, or an
    #   UNRESTRICTED sentinel. Entries may be addresses or CIDR ranges.
    def initialize(token: nil, allowed_ips: nil, logger: nil)
      @logger = logger
      @token = token.to_s.strip.presence
      @allowed_ips = resolve_allowed_ips(allowed_ips)
    end

    def token_required?
      @token.present?
    end

    # True when no network restriction applies (only reachable with a token).
    def network_unrestricted?
      @allowed_ips.empty?
    end

    def network_allowed?(ip)
      return true if network_unrestricted?

      candidate = normalize_ip(ip)
      return false if candidate.nil?

      @allowed_ips.any? { |range| range.include?(candidate) }
    end

    # Compares the request's bearer token against the configured secret in
    # constant time. Always true when no token is configured.
    def authenticated?(request)
      return true unless token_required?

      presented = bearer_token(request)
      return false if presented.blank?

      ActiveSupport::SecurityUtils.secure_compare(presented, @token)
    end

    # One-line posture summary for boot logging. Never includes the secret.
    def describe
      network = network_unrestricted? ? "any IP" : "#{@allowed_ips.size} allowed range(s)"
      auth = token_required? ? "bearer token required" : "no token (unauthenticated)"
      "#{auth}, #{network}"
    end

    private

    def bearer_token(request)
      header = request.get_header("HTTP_AUTHORIZATION").to_s
      return nil unless header.match?(BEARER_PREFIX)

      header.sub(BEARER_PREFIX, "").strip
    end

    def resolve_allowed_ips(raw)
      entries = split_entries(raw)

      return default_ranges if entries.empty?

      if entries.any? { |entry| UNRESTRICTED.include?(entry.downcase) }
        return [] if token_required?

        warn(
          "#{ALLOWED_IPS_ENV} requests unrestricted access but #{TOKEN_ENV} is not set. " \
          "Refusing to expose an unauthenticated MCP endpoint; falling back to loopback and private ranges."
        )
        return default_ranges
      end

      parsed = parse_ranges(entries)
      parsed = narrow_to_defaults(parsed) unless token_required?

      parsed.empty? ? default_ranges : parsed
    end

    # Without a token the allowlist may only narrow the default ranges, never
    # widen them: an explicit public range such as 0.0.0.0/0 is as unsafe as the
    # UNRESTRICTED sentinel, and parses cleanly, so it has to be caught here.
    def narrow_to_defaults(ranges)
      ranges.select do |range|
        next true if within_defaults?(range)

        warn(
          "#{ALLOWED_IPS_ENV} entry #{range} reaches beyond the loopback and private ranges, " \
          "which requires #{TOKEN_ENV}. Ignoring it."
        )
        false
      end
    end

    def within_defaults?(range)
      default_ranges.any? do |allowed|
        allowed.family == range.family && allowed.include?(range)
      end
    end

    def default_ranges
      @default_ranges ||= parse_ranges(DEFAULT_RANGES)
    end

    def split_entries(raw)
      case raw
      when nil then []
      when Array then raw.map { |entry| entry.to_s.strip }.reject(&:empty?)
      else raw.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end

    def parse_ranges(entries)
      entries.filter_map do |entry|
        IPAddr.new(entry)
      rescue IPAddr::Error
        warn("Ignoring unparseable #{ALLOWED_IPS_ENV} entry: #{entry.inspect}")
        nil
      end
    end

    # IPv4-mapped IPv6 addresses (::ffff:127.0.0.1) must be compared as IPv4 so
    # they match an IPv4 CIDR range.
    def normalize_ip(ip)
      addr = IPAddr.new(ip.to_s)
      addr.ipv4_mapped? ? addr.native : addr
    rescue IPAddr::Error
      nil
    end

    def warn(message)
      @logger&.warn("[McpAccessPolicy] #{message}")
    end
  end
end
