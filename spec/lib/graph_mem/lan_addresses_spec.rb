# frozen_string_literal: true

require "rails_helper"

# 1.79.0: `@lan` in the MCP allowlists is this machine's LAN: the default-route interface's subnet.
RSpec.describe GraphMem::LanAddresses do
  # A Socket::Ifaddr stand-in: the four readers LanAddresses uses.
  def interface(name, ip, mask, up: true, point_to_point: false)
    flags = (up ? Socket::IFF_UP : 0) | (point_to_point ? Socket::IFF_POINTOPOINT : 0)
    Struct.new(:name, :addr, :netmask, :flags).new(name, Addrinfo.ip(ip), Addrinfo.ip(mask), flags)
  end

  let(:interfaces) do
    [ interface("lo", "127.0.0.1", "255.0.0.0"), interface("enp3s0", "10.9.8.18", "255.255.255.0"),
      interface("wlp2s0", "10.20.30.40", "255.255.0.0"), interface("docker0", "172.17.0.1", "255.255.0.0"),
      interface("br-c747094b5c17", "172.30.42.1", "255.255.255.0"), interface("veth12ab", "169.254.1.1", "255.255.0.0"),
      interface("eth9", "192.0.2.10", "255.255.255.0"), interface("eth8", "10.9.0.5", "255.0.0.0"),
      interface("eth7", "192.168.7.7", "255.255.255.0", up: false) ]
  end

  # /proc/net/route text: a default route per [interface, metric] (flags 0x3: up, gateway; or 0x2:
  # down), plus the on-link route of the first one.
  def routes(*defaults, down: [])
    lines = defaults.map { |name, metric| "#{name}\t00000000\t0108090A\t#{down.include?(name) ? '0002' : '0003'}\t0\t0\t#{metric}\t00000000\t0\t0\t0" }
    lines << "#{defaults.first&.first || 'enp3s0'}\t0008090A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0"
    "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n#{lines.join("\n")}\n"
  end

  after { described_class.reset! }

  it "reads only the interface of the lowest-metric default route: its subnet, its address, the host names" do
    snapshot = described_class.read(interfaces: interfaces, hostname: "Synth-Box.home.lan", routes: routes([ "enp3s0", 100 ], [ "wlp2s0", 600 ]))

    expect(snapshot.ranges).to eq(%w[10.9.8.0/24])
    expect(snapshot.hosts).to eq(%w[10.9.8.18 synth-box synth-box.local])
  end

  it "follows the default route to another interface, ignoring a route that is down" do
    table = routes([ "enp3s0", 100 ], [ "wlp2s0", 600 ], down: [ "enp3s0" ])

    expect(described_class.read(interfaces: interfaces, hostname: "synth-box", routes: table).ranges).to eq(%w[10.20.0.0/16])
  end

  it "reads an empty LAN with no default route, or an unreadable route table" do
    expect(described_class.read(interfaces: interfaces, hostname: "synth-box", routes: routes)).to have_attributes(ranges: [], hosts: [], empty?: true)

    allow(File).to receive(:read).with(described_class::ROUTE_TABLE).and_raise(Errno::ENOENT)
    expect(described_class.read(interfaces: interfaces, hostname: "synth-box")).to have_attributes(ranges: [], hosts: [])
  end

  it "reads an empty LAN when the default route goes through a tunnel, a bridge or an unusable address" do
    refused = [ interface("wg0", "10.66.0.2", "255.255.255.0"), interface("tun0", "10.8.0.6", "255.255.255.0"),
                interface("nordlynx", "10.5.0.2", "255.255.0.0"), interface("kube-bridge", "10.244.0.1", "255.255.255.0"),
                interface("vpn-office", "10.44.0.9", "255.255.255.0", point_to_point: true) ] + interfaces

    %w[wg0 tun0 nordlynx kube-bridge vpn-office docker0 lo eth9 eth8 eth7].each do |name|
      snapshot = described_class.read(interfaces: refused, hostname: "synth-box", routes: routes([ name, 50 ], [ "enp3s0", 100 ]))

      expect(snapshot).to have_attributes(ranges: [], hosts: []), name
    end
  end

  it "skips an unusable host name" do
    snapshot = described_class.read(interfaces: interfaces, hostname: "not a host", routes: routes([ "enp3s0", 100 ]))

    expect(snapshot.hosts).to eq(%w[10.9.8.18])
  end

  it "reads an empty LAN when the interfaces can't be read" do
    allow(Socket).to receive(:getifaddrs).and_raise(Errno::EACCES)

    expect(described_class.read(hostname: "synth-box", routes: routes([ "enp3s0", 100 ]))).to have_attributes(ranges: [], hosts: [])
  end

  it "expands @lan in either list, in place, any case, leaving other entries" do
    allow(described_class).to receive(:read).and_return(described_class.read(interfaces: interfaces, hostname: "synth-box", routes: routes([ "enp3s0", 100 ])))

    expect(described_class.expand_ips(%w[127.0.0.0/8 @LAN 10.8.0.0/24])).to eq(%w[127.0.0.0/8 10.9.8.0/24 10.8.0.0/24])
    expect(described_class.expand_hosts(%w[@lan synth-box.lan])).to eq(%w[10.9.8.18 synth-box synth-box.local synth-box.lan])
    expect(described_class.token?(%w[127.0.0.1 @lan])).to be(true)
    expect(described_class.token?(%w[127.0.0.1])).to be(false)
  end

  it "reports a change at most every REFRESH_SECONDS" do
    home = described_class.read(interfaces: interfaces, hostname: "synth-box", routes: routes([ "enp3s0", 100 ]))
    roaming = [ interface("wlp2s0", "172.20.1.5", "255.255.0.0") ]
    away = described_class.read(interfaces: roaming, hostname: "synth-box", routes: routes([ "wlp2s0", 600 ]))
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
