# frozen_string_literal: true

require "rails_helper"

# 1.79.0: `@lan` in GRAPH_MEM_MCP_ALLOWED_IPS / _HOSTS is expanded when the lists are built, and
# the lists are rebuilt when this machine's LAN changes.
RSpec.describe "MCP allowlists with @lan" do
  let(:home) { GraphMem::LanAddresses::Snapshot.new(ranges: %w[192.168.1.0/24], hosts: %w[192.168.1.18 wks-2b wks-2b.local]) }
  let(:away) { GraphMem::LanAddresses::Snapshot.new(ranges: %w[172.20.0.0/16], hosts: %w[172.20.1.5 wks-2b wks-2b.local]) }
  let(:env_keys) { %w[GRAPH_MEM_MCP_ALLOWED_IPS GRAPH_MEM_MCP_ALLOWED_HOSTS] }

  around do |example|
    saved = env_keys.to_h { |key| [ key, ENV[key] ] }
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    GraphMem::LanAddresses.reset!
    GraphMem::OfficialMcp.reset!
  end

  def client(ip) = Rack::Request.new(Rack::MockRequest.env_for("/mcp", "REMOTE_ADDR" => ip))

  it "expands @lan in the IP list to this machine's LAN subnets" do
    allow(GraphMem::LanAddresses).to receive(:current).and_return(home)

    policy = GraphMem::McpAccessPolicy.from_env(env: { "GRAPH_MEM_MCP_ALLOWED_IPS" => "127.0.0.0/8,::1,172.16.0.0/12,@lan" })

    expect(policy.request_allowed?(client("192.168.1.100"))).to be(true)
    expect(policy.request_allowed?(client("192.168.0.100"))).to be(false)
    expect(policy.request_allowed?(client("10.0.0.5"))).to be(false)
  end

  it "expands @lan in the host list to this machine's addresses and names" do
    allow(GraphMem::LanAddresses).to receive(:current).and_return(home)

    hosts = GraphMem::McpAccessLists.entries!(:hosts, env: { "GRAPH_MEM_MCP_ALLOWED_HOSTS" => "@lan,wks-2b.lan" })

    expect(hosts).to eq(%w[192.168.1.18 wks-2b wks-2b.local wks-2b.lan])
  end

  it "rebuilds the policy and the transports when the LAN changes, and only then" do
    ENV["GRAPH_MEM_MCP_ALLOWED_IPS"] = "127.0.0.0/8,::1,172.16.0.0/12,@lan"
    ENV["GRAPH_MEM_MCP_ALLOWED_HOSTS"] = "@lan"
    changed = false
    allow(GraphMem::LanAddresses).to receive(:refresh!) { changed }
    allow(GraphMem::LanAddresses).to receive(:current) { changed ? away : home }
    allow(GraphMem::OfficialMcp::Transports).to receive(:reset!).and_call_original

    expect(GraphMem::OfficialMcp.access_policy.request_allowed?(client("192.168.1.100"))).to be(true)
    expect(GraphMem::OfficialMcp::Transports.allowed_hosts).to include("192.168.1.18")

    changed = true
    policy = GraphMem::OfficialMcp.access_policy

    expect(policy.request_allowed?(client("192.168.1.100"))).to be(false)
    expect(policy.request_allowed?(client("172.20.9.9"))).to be(true)
    expect(GraphMem::OfficialMcp::Transports).to have_received(:reset!)
    expect(GraphMem::OfficialMcp::Transports.allowed_hosts).to include("172.20.1.5")
    expect(GraphMem::OfficialMcp::Transports.allowed_hosts).not_to include("192.168.1.18")
  end

  it "never reads the interfaces without @lan" do
    ENV["GRAPH_MEM_MCP_ALLOWED_IPS"] = "127.0.0.0/8,192.168.1.0/24"
    ENV.delete("GRAPH_MEM_MCP_ALLOWED_HOSTS")
    allow(GraphMem::LanAddresses).to receive(:refresh!)

    expect(GraphMem::OfficialMcp.refresh_lan!).to be(false)
    expect(GraphMem::LanAddresses).not_to have_received(:refresh!)
  end
end
