# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpAccessPolicy do
  let(:logger) { instance_spy(Logger) }
  let(:token) { SecureRandom.hex(16) }

  def request_with(authorization: nil)
    env = Rack::MockRequest.env_for("/mcp", method: "POST")
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    Rack::Request.new(env)
  end

  describe "with no token configured" do
    subject(:policy) { described_class.new(logger: logger) }

    it "does not require a token" do
      expect(policy.token_required?).to be(false)
    end

    it "authenticates any request" do
      expect(policy.authenticated?(request_with)).to be(true)
    end

    it "still restricts the network to loopback and private ranges" do
      expect(policy.network_unrestricted?).to be(false)
      expect(policy.network_allowed?("127.0.0.1")).to be(true)
      expect(policy.network_allowed?("192.168.0.18")).to be(true)
      expect(policy.network_allowed?("10.1.2.3")).to be(true)
      expect(policy.network_allowed?("172.16.5.5")).to be(true)
    end

    it "rejects public addresses" do
      expect(policy.network_allowed?("8.8.8.8")).to be(false)
      expect(policy.network_allowed?("203.0.113.7")).to be(false)
    end
  end

  describe "with a token configured" do
    subject(:policy) { described_class.new(token: token, logger: logger) }

    it "requires a token" do
      expect(policy.token_required?).to be(true)
    end

    it "accepts the matching bearer token" do
      expect(policy.authenticated?(request_with(authorization: "Bearer #{token}"))).to be(true)
    end

    it "accepts a case-insensitive scheme with extra whitespace" do
      expect(policy.authenticated?(request_with(authorization: "bearer   #{token}"))).to be(true)
    end

    it "rejects a missing Authorization header" do
      expect(policy.authenticated?(request_with)).to be(false)
    end

    it "rejects a wrong token" do
      expect(policy.authenticated?(request_with(authorization: "Bearer #{SecureRandom.hex(16)}"))).to be(false)
    end

    it "rejects a token presented without the Bearer scheme" do
      expect(policy.authenticated?(request_with(authorization: token))).to be(false)
    end

    it "rejects an empty bearer value" do
      expect(policy.authenticated?(request_with(authorization: "Bearer   "))).to be(false)
    end

    it "does not widen the network by itself" do
      expect(policy.network_allowed?("8.8.8.8")).to be(false)
    end
  end

  describe "network allowlist configuration" do
    it "accepts a comma-separated list of addresses and CIDR ranges" do
      policy = described_class.new(token: token, allowed_ips: "127.0.0.1, 198.51.100.0/24", logger: logger)

      expect(policy.network_allowed?("127.0.0.1")).to be(true)
      expect(policy.network_allowed?("198.51.100.42")).to be(true)
      expect(policy.network_allowed?("198.51.101.1")).to be(false)
      expect(policy.network_allowed?("192.168.0.18")).to be(false)
    end

    it "accepts an array" do
      policy = described_class.new(allowed_ips: [ "10.0.0.0/8" ], logger: logger)

      expect(policy.network_allowed?("10.9.9.9")).to be(true)
      expect(policy.network_allowed?("192.168.0.1")).to be(false)
    end

    it "matches IPv4-mapped IPv6 addresses against IPv4 ranges" do
      policy = described_class.new(logger: logger)

      expect(policy.network_allowed?("::ffff:127.0.0.1")).to be(true)
    end

    it "allows IPv6 loopback" do
      policy = described_class.new(logger: logger)

      expect(policy.network_allowed?("::1")).to be(true)
    end

    it "rejects an unparseable client address" do
      policy = described_class.new(logger: logger)

      expect(policy.network_allowed?("not-an-ip")).to be(false)
      expect(policy.network_allowed?(nil)).to be(false)
    end

    it "ignores unparseable entries and warns" do
      policy = described_class.new(allowed_ips: "10.0.0.0/8, nonsense", logger: logger)

      expect(policy.network_allowed?("10.0.0.1")).to be(true)
      expect(logger).to have_received(:warn).with(/Ignoring unparseable/)
    end

    it "falls back to the defaults when every entry is unparseable" do
      policy = described_class.new(allowed_ips: "nonsense", logger: logger)

      expect(policy.network_allowed?("127.0.0.1")).to be(true)
    end
  end

  describe "the at-least-one-control invariant" do
    GraphMem::McpAccessPolicy::UNRESTRICTED.each do |sentinel|
      it "lifts the network restriction for #{sentinel.inspect} when a token is configured" do
        policy = described_class.new(token: token, allowed_ips: sentinel, logger: logger)

        expect(policy.network_unrestricted?).to be(true)
        expect(policy.network_allowed?("8.8.8.8")).to be(true)
      end

      it "refuses #{sentinel.inspect} without a token and falls back to the defaults" do
        policy = described_class.new(allowed_ips: sentinel, logger: logger)

        expect(policy.network_unrestricted?).to be(false)
        expect(policy.network_allowed?("8.8.8.8")).to be(false)
        expect(policy.network_allowed?("192.168.0.18")).to be(true)
        expect(logger).to have_received(:warn).with(/Refusing to expose an unauthenticated MCP endpoint/)
      end
    end

    # An explicit all-encompassing CIDR parses cleanly, so the sentinel check
    # alone is not enough to uphold the invariant.
    [ "0.0.0.0/0", "::/0", "0.0.0.0/0,::/0", "8.8.8.8", "198.51.100.0/24", "10.0.0.0/7" ].each do |entry|
      it "blocks public addresses for #{entry.inspect} without a token" do
        policy = described_class.new(allowed_ips: entry, logger: logger)

        expect(policy.network_allowed?("8.8.8.8")).to be(false)
        expect(policy.network_allowed?("203.0.113.7")).to be(false)
      end
    end

    it "warns when an entry reaches beyond the private ranges without a token" do
      described_class.new(allowed_ips: "0.0.0.0/0", logger: logger)

      expect(logger).to have_received(:warn).with(/reaches beyond the loopback and private ranges/)
    end

    it "still allows narrowing the defaults without a token" do
      policy = described_class.new(allowed_ips: "192.168.0.0/24", logger: logger)

      expect(policy.network_allowed?("192.168.0.18")).to be(true)
      expect(policy.network_allowed?("192.168.9.9")).to be(false)
    end

    it "keeps in-range entries and drops over-wide ones from a mixed list" do
      policy = described_class.new(allowed_ips: "192.168.0.0/24, 8.8.8.8", logger: logger)

      expect(policy.network_allowed?("192.168.0.18")).to be(true)
      expect(policy.network_allowed?("8.8.8.8")).to be(false)
    end

    it "honours a wide range once a token is configured" do
      policy = described_class.new(token: token, allowed_ips: "0.0.0.0/0", logger: logger)

      expect(policy.network_allowed?("8.8.8.8")).to be(true)
    end

    it "never leaves an instance both unauthenticated and publicly reachable" do
      candidates = [ nil, "any", "all", "*", "0.0.0.0/0", "::/0", "8.8.8.8", "nonsense" ]

      candidates.each do |entry|
        policy = described_class.new(allowed_ips: entry, logger: logger)

        expect(policy.network_allowed?("8.8.8.8")).to be(false),
          "expected #{entry.inspect} with no token to block public addresses"
      end
    end
  end

  describe ".from_env" do
    it "reads the token and allowlist from the environment" do
      policy = described_class.from_env(
        env: { described_class::TOKEN_ENV => token, described_class::ALLOWED_IPS_ENV => "any" },
        logger: logger
      )

      expect(policy.token_required?).to be(true)
      expect(policy.network_unrestricted?).to be(true)
    end

    it "treats a blank token as absent" do
      policy = described_class.from_env(env: { described_class::TOKEN_ENV => "   " }, logger: logger)

      expect(policy.token_required?).to be(false)
    end

    it "defaults to unauthenticated private-range access with an empty environment" do
      policy = described_class.from_env(env: {}, logger: logger)

      expect(policy.token_required?).to be(false)
      expect(policy.network_allowed?("192.168.0.18")).to be(true)
      expect(policy.network_allowed?("8.8.8.8")).to be(false)
    end
  end

  describe "#describe" do
    it "summarises an unauthenticated posture" do
      expect(described_class.new(logger: logger).describe)
        .to eq("no token (unauthenticated), 7 allowed range(s)")
    end

    it "summarises an authenticated open posture" do
      policy = described_class.new(token: token, allowed_ips: "any", logger: logger)

      expect(policy.describe).to eq("bearer token required, any IP")
    end

    it "never includes the token" do
      policy = described_class.new(token: token, logger: logger)

      expect(policy.describe).not_to include(token)
    end
  end
end
