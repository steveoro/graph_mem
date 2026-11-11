# frozen_string_literal: true

require "ipaddr"
require "socket"

module GraphMem
  # The `@lan` entry of the MCP allowlists (1.79.0): this machine's own LAN, read from its network
  # interfaces whenever graph_mem builds the lists, instead of an address fixed when the container
  # was created. A reboot on another subnet, or a laptop that joins another network, needs no
  # restart with new values: the next request after the change rebuilds the lists
  # (OfficialMcp.refresh_lan!, at most every REFRESH_SECONDS).
  #
  # The container runs on the host network (docker-compose.yml), so on Linux it sees the host's
  # interfaces. Docker Desktop (macOS) runs it in a VM that can't, so bin/up writes literal
  # addresses there instead.
  #
  # An interface counts when it is up, not loopback, not point-to-point, not a container or VM
  # bridge and not a VPN tunnel (VIRTUAL), and its IPv4 address is private (10/8, 172.16/12,
  # 192.168/16) with a /16-/30 prefix. Unlike bin/up before 1.79.0, which took only the
  # default-route interface, every such interface counts (wired and Wi-Fi at once). `@lan` then means:
  # - in GRAPH_MEM_MCP_ALLOWED_IPS: each such interface's subnet ("10.9.8.0/24");
  # - in GRAPH_MEM_MCP_ALLOWED_HOSTS: each such address, the host name and "<host name>.local".
  #
  #   GraphMem::LanAddresses.expand_ips(%w[127.0.0.0/8 @lan]) # => ["127.0.0.0/8", "10.9.8.0/24"]
  #   GraphMem::LanAddresses.expand_hosts(%w[@lan])           # => ["10.9.8.18", "synth-box", "synth-box.local"]
  module LanAddresses
    TOKEN = "@lan"
    REFRESH_SECONDS = 30
    PRIVATE_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16].map { |range| IPAddr.new(range) }.freeze
    PREFIXES = (16..30)
    # Interfaces of containers, bridges, VMs and VPN tunnels: never "the LAN". A VPN peer must not
    # join the unauthenticated allowlist; point-to-point links (wg, tun, ppp) are refused by flag too.
    VIRTUAL = /\A(docker|br-|veth|virbr|vmnet|vboxnet|cni|flannel|cali|cilium|weave|kube|vxlan|lxc|lxd|incusbr|podman|
                  tailscale|zt|wg|tun|tap|ppp|utun|ipsec|nordlynx|wt)/x
    HOST_LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    # `ranges` the subnets ("10.9.8.0/24"), `hosts` the addresses and names.
    Snapshot = Data.define(:ranges, :hosts) do
      def empty? = ranges.empty?
    end

    @mutex = Mutex.new
    @snapshot = nil
    @read_at = nil

    class << self
      # @param entries [Array<String>] IP list entries
      # @return [Array<String>] each `@lan` replaced by the LAN subnets (none when there is no LAN)
      def expand_ips(entries)
        expand(entries) { current.ranges }
      end

      # @param entries [Array<String>] host list entries
      # @return [Array<String>] each `@lan` replaced by the LAN addresses and host names
      def expand_hosts(entries)
        expand(entries) { current.hosts }
      end

      # @param entries [Array<String>]
      # @return [Boolean] the list holds `@lan`
      def token?(entries)
        Array(entries).any? { |entry| entry.to_s.strip.casecmp?(TOKEN) }
      end

      # @return [Snapshot] the last one read (reading it the first time)
      def current
        @mutex.synchronize { @snapshot ||= stamp(read) }
      end

      # Reads the interfaces again when the last read is older than REFRESH_SECONDS.
      #
      # @return [Boolean] whether the LAN changed since the last read
      def refresh!
        @mutex.synchronize do
          next false if @snapshot && monotonic - @read_at < REFRESH_SECONDS

          previous = @snapshot
          @snapshot = stamp(read)
          !previous.nil? && previous != @snapshot
        end
      end

      # Forgets the last read (specs).
      def reset!
        @mutex.synchronize { @snapshot = @read_at = nil }
      end

      # @param interfaces [Array<Socket::Ifaddr>, nil] injectable for specs (nil: this machine's)
      # @param hostname [String, nil]
      # @return [Snapshot] empty when the interfaces can't be read
      def read(interfaces: nil, hostname: nil)
        # Read here, not as default arguments, so the rescue below covers a failed read.
        interfaces ||= Socket.getifaddrs
        hostname ||= Socket.gethostname
        addresses = interfaces.filter_map { |interface| lan_address(interface) }.uniq
        name = hostname.to_s.split(".").first.to_s.downcase
        names = name.match?(HOST_LABEL) ? [ name, "#{name}.local" ] : []
        Snapshot.new(ranges: addresses.map { |_ip, range| range }.uniq, hosts: addresses.map(&:first) + names)
      rescue SystemCallError, SocketError
        Snapshot.new(ranges: [], hosts: [])
      end

      private

      def expand(entries, &replacement)
        Array(entries).flat_map { |entry| entry.to_s.strip.casecmp?(TOKEN) ? replacement.call : [ entry ] }.uniq
      end

      def stamp(snapshot)
        @read_at = monotonic
        snapshot
      end

      # @return [Array(String, String), nil] the address and its "network/prefix", when it counts
      def lan_address(interface)
        addr = interface.addr
        mask = interface.netmask
        return nil unless addr&.ipv4? && mask&.ipv4? && !addr.ipv4_loopback?
        return nil if interface.name.to_s.match?(VIRTUAL) || (interface.flags & Socket::IFF_UP).zero?
        return nil if interface.flags.anybits?(Socket::IFF_POINTOPOINT)

        ip = IPAddr.new(addr.ip_address)
        prefix = IPAddr.new(mask.ip_address).to_i.to_s(2).count("1")
        return nil unless PREFIXES.cover?(prefix) && PRIVATE_RANGES.any? { |range| range.include?(ip) }

        [ ip.to_s, "#{IPAddr.new("#{ip}/#{prefix}")}/#{prefix}" ]
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
