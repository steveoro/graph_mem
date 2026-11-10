# frozen_string_literal: true

require "rails_helper"

# 1.79.0: `@lan` in the MCP allowlists is this machine's LAN, read from its interfaces.
RSpec.describe GraphMem::LanAddresses do
  # A Socket::Ifaddr stand-in: the four readers LanAddresses uses.
  def interface(name, ip, mask, up: true)
    Struct.new(:name, :addr, :netmask, :flags).new(name, Addrinfo.ip(ip), Addrinfo.ip(mask), up ? Socket::IFF_UP : 0)
  end

  let(:interfaces) do
    [ interface("lo", "127.0.0.1", "255.0.0.0"), interface("enp3s0", "192.168.1.18", "255.255.255.0"),
      interface("wlp2s0", "10.20.30.40", "255.255.0.0"), interface("docker0", "172.17.0.1", "255.255.0.0"),
      interface("br-c747094b5c17", "172.30.42.1", "255.255.255.0"), interface("veth12ab", "169.254.1.1", "255.255.0.0"),
      interface("eth9", "192.0.2.10", "255.255.255.0"), interface("eth8", "10.9.0.5", "255.0.0.0"),
      interface("eth7", "192.168.7.7", "255.255.255.0", up: false) ]
  end

  after { described_class.reset! }

  it "reads each up, non-virtual, private /16-/30 interface: its subnet, its address, and the host names" do
    snapshot = described_class.read(interfaces: interfaces, hostname: "WKS-2b.home.lan")

    expect(snapshot.ranges).to eq(%w[192.168.1.0/24 10.20.0.0/16])
    expect(snapshot.hosts).to eq(%w[192.168.1.18 10.20.30.40 wks-2b wks-2b.local])
  end

  it "reads an empty LAN without a usable interface, and skips an unusable host name" do
    snapshot = described_class.read(interfaces: interfaces.first(1), hostname: "not a host")

    expect(snapshot).to have_attributes(ranges: [], hosts: [], empty?: true)
  end

  it "expands @lan in either list, in place, any case, leaving other entries" do
    allow(described_class).to receive(:read).and_return(described_class.read(interfaces: interfaces, hostname: "wks-0"))

    expect(described_class.expand_ips(%w[127.0.0.0/8 @LAN 10.8.0.0/24])).to eq(%w[127.0.0.0/8 192.168.1.0/24 10.20.0.0/16 10.8.0.0/24])
    expect(described_class.expand_hosts(%w[@lan wks-0.lan])).to eq(%w[192.168.1.18 10.20.30.40 wks-0 wks-0.local wks-0.lan])
    expect(described_class.token?(%w[127.0.0.1 @lan])).to be(true)
    expect(described_class.token?(%w[127.0.0.1])).to be(false)
  end

  it "reports a change at most every REFRESH_SECONDS" do
    home = described_class.read(interfaces: interfaces, hostname: "wks-2b")
    away = described_class.read(interfaces: [ interface("wlp2s0", "172.20.1.5", "255.255.0.0") ], hostname: "wks-2b")
    allow(described_class).to receive(:read).and_return(home, home, away)
    now = 1_000.0
    allow(described_class).to receive(:monotonic) { now }

    expect(described_class.refresh!).to be(false) # the first read
    now += 5
    expect(described_class.refresh!).to be(false) # too soon: not read again
    now += described_class::REFRESH_SECONDS
    expect(described_class.refresh!).to be(false) # read again: the same LAN
    now += described_class::REFRESH_SECONDS
    expect(described_class.refresh!).to be(true)
    expect(described_class.current.ranges).to eq(%w[172.20.0.0/16])
  end
end
