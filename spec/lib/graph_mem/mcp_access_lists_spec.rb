# frozen_string_literal: true

require "rails_helper"

# UI-2a A1/A2: the merged MCP allowlists and the validation of their additive part.
# Synthetic values only: documentation IP ranges, *.test / *.localhost names.
RSpec.describe GraphMem::McpAccessLists do
  let(:token_env) { { "GRAPH_MEM_MCP_TOKEN" => "synthetic-token" } }

  def validate(kind, raw, env = {}) = described_class.validate(kind, raw, env: env)

  describe ".entries" do
    it "lists the ENV entries first, then the stored ones, de-duplicated case-insensitively" do
      AppSettings.mcp_extra_allowed_hosts = "synth-lan.test,ENV-Host.test,lan-box.test"

      entries = described_class.entries(:hosts, env: { "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "env-host.test, synth-lan.test" })

      expect(entries).to eq(%w[env-host.test synth-lan.test lan-box.test])
    end

    it "reads a change made by another process, with no cache in between" do
      AppSettings.mcp_extra_allowed_origins = "http://synth-ui.localhost:3002"
      AppSettings.where(var: "mcp_extra_allowed_origins").update_all(value: "--- http://synth-ui.localhost:3003\n")

      expect(described_class.extra_entries(:origins)).to eq([ "http://synth-ui.localhost:3003" ])
    end

    it "reads the stored part as empty when the settings can't be read, and the bang forms raise" do
      allow(AppSettings).to receive(:uncached_string).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect(described_class.extra_entries(:ips)).to eq([])
      expect(described_class.entries(:hosts, env: { "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "env-host.test" })).to eq(%w[env-host.test])
      expect { described_class.extra_entries!(:ips) }.to raise_error(described_class::ReadError)
      expect { described_class.entries!(:hosts) }.to raise_error(described_class::ReadError)
    end

    it "warns once per outage: a successful read re-arms the warning" do
      described_class.extra_entries(:ips) # an earlier example may have left the warning disarmed
      outage = true
      allow(AppSettings).to receive(:uncached_string).and_wrap_original do |original, *args|
        raise ActiveRecord::ConnectionNotEstablished if outage

        original.call(*args)
      end
      allow(Rails.logger).to receive(:warn)

      2.times { described_class.extra_entries(:ips) }
      outage = false
      described_class.extra_entries(:ips)
      outage = true
      described_class.extra_entries(:ips)

      expect(Rails.logger).to have_received(:warn).with(/Couldn't read the MCP allowlist settings/).twice
    end
  end

  describe ".validate" do
    it "splits on commas and newlines and drops blanks" do
      expect(validate(:hosts, "a.test,\n b.test ,, \nc.test")[:entries]).to eq(%w[a.test b.test c.test])
    end

    context "with IPs" do
      it "normalizes ranges and warns when host bits are masked" do
        result = validate(:ips, "192.168.0.21/24, 10.8.0.5, fd00::1/64", token_env.merge("GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.0/8"))

        expect(result).to include(entries: %w[192.168.0.0/24 10.8.0.5 fd00::/64], errors: [])
        expect(result[:warnings]).to include("192.168.0.21/24: host bits masked, saved as 192.168.0.0/24")
      end

      it "refuses broad and IPv6 public ranges without a token" do
        %w[0.0.0.0/1 0.0.0.0/0 ::/0 2000::/3 ::ffff:0:0/96 2001:db8::/32].each do |entry|
          result = validate(:ips, entry)
          expect(result[:errors].size).to eq(1), entry
          expect(result[:entries]).to be_empty
        end
      end

      it "refuses a /0 even with a token, since it lifts the restriction like any" do
        %w[0.0.0.0/0 ::/0 ::ffff:0:0/96].each do |entry|
          expect(validate(:ips, entry, token_env)[:errors].sole).to include("a /0 lifts the IP restriction"), entry
        end
        expect(validate(:ips, "0.0.0.0/1", token_env)).to include(entries: [ "0.0.0.0/1" ], errors: [])
      end

      it "stores an IPv4-mapped entry in native form, the form client addresses are matched in" do
        result = validate(:ips, "::ffff:10.8.0.0/120, ::FFFF:10.8.0.5", "GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.0/8")

        expect(result).to include(entries: %w[10.8.0.0/24 10.8.0.5], errors: [])
        expect(result[:warnings]).to eq([ "::ffff:10.8.0.0/120: saved as 10.8.0.0/24", "::FFFF:10.8.0.5: saved as 10.8.0.5" ])
        expect(validate(:ips, "::ffff:198.51.100.0/120")[:errors].sole).to start_with("198.51.100.0/24: is a public range")
      end

      it "refuses any, all and *, with or without a token" do
        [ {}, token_env ].each do |env|
          expect(validate(:ips, "any, ALL, *", env)[:errors].size).to eq(3)
        end
      end

      it "refuses an unparseable entry, naming it" do
        expect(validate(:ips, "10.8.0.0/24, 10.8.0.300")[:errors]).to eq([ "10.8.0.300: isn't an IP address or a CIDR range" ])
      end

      it "refuses a public range without a token and accepts it with a warning with one" do
        expect(validate(:ips, "198.51.100.0/24")[:errors]).to eq([ "198.51.100.0/24: is a public range: it needs GRAPH_MEM_MCP_TOKEN, as in ENV" ])

        result = validate(:ips, "198.51.100.0/24", token_env)
        expect(result).to include(entries: [ "198.51.100.0/24" ], errors: [])
        expect(result[:warnings].sole).to include("public range", "If the token is removed, this entry stops applying")
      end

      it "warns that a range the ENV or default ranges already cover has no effect" do
        result = validate(:ips, "10.8.0.0/24")

        expect(result[:entries]).to eq([ "10.8.0.0/24" ])
        expect(result[:warnings]).to eq([ "10.8.0.0/24: already covered by the ENV or default ranges, so it has no effect" ])
        expect(validate(:ips, "10.8.0.0/24", "GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.0/8")[:warnings]).to be_empty
      end

      it "reports an entry already in ENV as a duplicate and doesn't keep it" do
        result = validate(:ips, "10.8.0.0/24, 10.9.0.0/24", "GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.0/8, 10.8.0.0/24")

        expect(result).to include(entries: [ "10.9.0.0/24" ], duplicates: [ "10.8.0.0/24" ])
      end
    end

    context "with hosts" do
      it "lowercases names, IPv4 and IPv6 addresses with an optional port" do
        result = validate(:hosts, "Synth-LAN.test, synth-lan.test:3030, 192.0.2.18, 192.0.2.18:3030, [FD00::1], [fd00::1]:3030, fd00::2")

        expect(result).to include(errors: [], entries: %w[synth-lan.test synth-lan.test:3030 192.0.2.18 192.0.2.18:3030 fd00::1 [fd00::1]:3030 fd00::2])
      end

      it "drops the loopback names, which are always accepted" do
        result = validate(:hosts, "localhost, 127.0.0.1:3030, [::1]")

        expect(result[:entries]).to be_empty
        expect(result[:warnings].size).to eq(3)
        expect(result[:warnings]).to all(end_with("loopback names are always accepted"))
      end

      {
        "*" => "wildcards", "*.lan" => "wildcards", "any" => "wildcards", "all" => "wildcards",
        "http://synth-lan.test" => "without a scheme", "synth-lan.test/mcp" => "may not contain a path",
        "user@synth-lan.test" => "user info", "synth lan.test" => "spaces", "synth-lan.test:0" => "optional :port",
        "synth-lan.test:65536" => "optional :port", "-synth.test" => "isn't a host name", "300.1.2.3" => "isn't a host name",
        "[fd00::zz]" => "isn't a host name", "#{'a' * 64}.test" => "isn't a host name"
      }.each do |input, message|
        it "refuses #{input.truncate(24).inspect}" do
          expect(validate(:hosts, input)[:errors].sole).to start_with("#{input}:").and include(message)
        end
      end

      it "reports a host already in ENV as a duplicate, case-insensitively" do
        expect(validate(:hosts, "ENV-Host.test", "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "env-host.test"))
          .to include(entries: [], duplicates: [ "env-host.test" ])
      end
    end

    context "with origins" do
      it "lowercases, strips one trailing slash and the default port, with a warning each" do
        result = validate(:origins, "HTTP://Synth-UI.localhost:3002/, https://synth-ui.test:443, http://synth-ui.test:80, http://[fd00::1]:8080")

        expect(result).to include(errors: [], entries: %w[http://synth-ui.localhost:3002 https://synth-ui.test http://synth-ui.test http://[fd00::1]:8080])
        expect(result[:warnings]).to include("HTTP://Synth-UI.localhost:3002/: trailing / removed (browsers never send it)",
                                             "https://synth-ui.test:443: default port removed (browsers never send it)")
      end

      {
        "*" => "isn't an origin", "null" => "isn't an origin", "synth-ui.test" => "must look like",
        "ftp://synth-ui.test" => "only http and https", "http://synth-ui.test//" => "no path",
        "http://synth-ui.test/app" => "no path", "http://synth-ui.test?x=1" => "query", "http://synth-ui.test#top" => "fragment",
        "http://user@synth-ui.test" => "user info", "http://fd00::1" => "isn't a valid", "http://*.synth.test" => "isn't a valid"
      }.each do |input, message|
        it "refuses #{input.inspect}" do
          expect(validate(:origins, input)[:errors].sole).to start_with("#{input}:").and include(message)
        end
      end
    end
  end

  describe ".env_warnings" do
    it "flags ENV entries that can never match, without refusing them" do
      env = { "GRAPH_MEM_MCP_ALLOWED_ORIGINS" => "http://synth-ui.test/, http://synth-ui.test:3001",
              "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "https://synth-lan.test, synth-lan.test" }

      expect(described_class.env_warnings(:origins, env: env)).to eq([ "http://synth-ui.test/: an origin is scheme://host[:port] only, so it never matches" ])
      expect(described_class.env_warnings(:hosts, env: env)).to eq([ "https://synth-lan.test: a host has no scheme or path, so it never matches" ])
    end
  end
end
