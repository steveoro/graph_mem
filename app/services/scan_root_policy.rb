# frozen_string_literal: true

# The one boundary for project scans (mcp plan PR-0 §0.4): the dashboard forms, POST /api/v1/scan,
# MCP scan_project and job start all resolve their path through it.
#
# Hard roots come from GRAPH_MEM_SCAN_ROOTS (":"-separated; in a container it is the read-only
# home mount) or, natively, Dir.home. Inside them, the runtime subfolder filter
# (AppSettings.project_scan_subfolders, read uncached on every call) narrows what is scannable,
# and a hard denylist (hidden folders, secret files) applies on top.
#
# @example
#   result = ScanRootPolicy.resolve("/home/steve/Projects/foo")
#   result.ok    # => true
#   result.path  # => "/home/steve/Projects/foo" (the realpath to store and scan)
class ScanRootPolicy
  Result = Data.define(:ok, :path, :root, :code, :message, :warnings) do
    alias_method :ok?, :ok
  end

  MAX_INPUT_LENGTH = 4096
  SYSTEM_PATHS = %w[/usr /etc /bin /sbin /lib /lib32 /lib64 /libx32 /proc /sys /dev /var /boot].freeze
  CONTAINER_PATHS = %w[/rails /home/rails].freeze
  COMPOSE_VOLUME_LINE = "- ${GRAPH_MEM_SCAN_HOME:-${HOME}}:${GRAPH_MEM_SCAN_HOME:-${HOME}}:ro"

  class << self
    # Overridable for specs (mountinfo fixtures).
    attr_writer :mountinfo_path

    def mountinfo_path
      @mountinfo_path || Mounts::DEFAULT_MOUNTINFO
    end

    # @return [Boolean] true when the app runs in the container image
    def container?
      ENV["GRAPH_MEM_IN_CONTAINER"].present?
    end

    # @return [Boolean] false when GRAPH_MEM_SCANS=off
    def enabled?
      ENV.fetch("GRAPH_MEM_SCANS", "on").to_s.strip.downcase != "off"
    end

    # @return [Array<Hash>] +{ path:, configured:, mounted:, read_only:, readable:, error: }+ per
    #   configured root; +error+ is a message when the root can't be used
    def hard_roots
      configured_roots.map { |configured| inspect_root(configured) }
    end

    # @return [Array<Hash>] the usable hard roots (no +error+)
    def valid_hard_roots
      hard_roots.select { |root| root[:error].nil? }
    end

    # The folders scans may use: each valid hard root joined with each existing filter entry
    # (blank filter: the hard roots themselves). Never memoized: the filter is read on every call.
    #
    # @return [Array<Hash>] +{ path:, root: }+ with real paths
    def allowed_roots
      roots = valid_hard_roots
      entries = subfolder_entries(roots).reject { |entry| entry[:error] }
      return roots.map { |root| { path: root[:path], root: root[:path] } } if entries.empty?

      roots.flat_map do |root|
        entries.filter_map do |entry|
          real = realpath_or_nil(File.join(root[:path], entry[:path]))
          next unless real && contained?(root[:path], real) && File.directory?(real)
          next if Denylist.root_path_denied?(relative_to(root[:path], real))

          { path: real, root: root[:path] }
        end
      end.uniq
    end

    # @param input [String, nil] a path typed by a user, an API caller or an agent
    # @return [Result] +ok+ with the realpath, or a distinct +code+ with an actionable +message+
    def resolve(input)
      Resolver.new(self).call(input)
    end

    # @return [Boolean] true when +path+ is +root+ or inside it (both real, absolute paths)
    def contained?(root, path)
      path == root || path.start_with?("#{root.delete_suffix('/')}/")
    end

    # @param root_real [String] the project root (real path)
    # @param file_path [String] a file under it
    # @return [Boolean] true when the file must never be read (§0.3 rule 2), checked on the
    #   lexical path and on its realpath
    def denied_file?(root_real, file_path)
      candidates = [ file_path, realpath_or_nil(file_path) ].compact.uniq
      candidates.any? { |path| contained?(root_real, path) && Denylist.file_denied?(relative_to(root_real, path)) }
    end

    # Identity in 1.54.0; the seam for a future GRAPH_MEM_SCAN_PATH_MAP on non-identity hosts.
    def map_host_path(input)
      input
    end

    # @return [Hash] everything Settings, Home and the health JSON show about scans
    def status
      roots = hard_roots
      {
        enabled: enabled? && roots.any? { |root| root[:error].nil? },
        scans_switch: enabled?,
        mode: container? ? "container" : "native",
        hard_roots: roots,
        subfolders: subfolder_status(roots.select { |root| root[:error].nil? }),
        allowed_roots: allowed_roots.map { |root| root[:path] },
        denylist: Denylist.to_h,
        warnings: status_warnings(roots),
        compose_volume_line: COMPOSE_VOLUME_LINE
      }
    end

    # @return [Array<Hash>] the parsed filter entries for +roots+
    def subfolder_entries(roots = valid_hard_roots)
      Subfolders.parse(AppSettings.project_scan_subfolders_raw, hard_roots: roots.map { |root| root[:path] })
    end

    # The filter entries for +roots+, each with +exists:+ (the folder is there under some root).
    def subfolder_status(roots)
      subfolder_entries(roots).map do |entry|
        exists = entry[:error].nil? && roots.any? { |root| File.directory?(File.join(root[:path], entry[:path])) }
        entry.merge(exists: exists)
      end
    end

    def filter_blank?
      Subfolders.split(AppSettings.project_scan_subfolders_raw).empty?
    end

    def relative_to(root, path)
      path == root ? "" : path.delete_prefix("#{root.delete_suffix('/')}/")
    end

    def realpath_or_nil(path)
      File.realpath(path)
    rescue SystemCallError, ArgumentError
      nil
    end

    private

    def configured_roots
      raw = ENV["GRAPH_MEM_SCAN_ROOTS"].to_s
      roots = raw.split(":").map(&:strip).reject(&:empty?)
      roots = [ Dir.home ] if roots.empty? && !container?
      roots.map { |root| File.expand_path(root) }.uniq
    end

    def inspect_root(configured)
      real = realpath_or_nil(configured)
      root = { path: real || configured, configured: configured, mounted: nil, read_only: nil,
               readable: real ? File.readable?(real) && File.executable?(real) : false, error: nil }
      return root.merge(error: "#{configured} does not exist") unless real

      guard = overlap_error(real)
      return root.merge(error: guard) if guard
      return root unless container?

      mount = Mounts.lookup(real, mountinfo_path: mountinfo_path)
      return root.merge(mounted: false, error: "nothing is mounted at #{real}: add the volume line") unless mount

      root.merge(mounted: true, read_only: mount[:read_only])
    end

    # A hard root may not be "/" or overlap a system directory (and, in the container, the app
    # or the container user's home).
    def overlap_error(real)
      return "/ can't be a scan root" if real == "/"

      guarded = SYSTEM_PATHS + (container? ? CONTAINER_PATHS + [ Rails.root.to_s ] : [])
      hit = guarded.find { |path| contained?(path, real) || contained?(real, path) }
      "#{real} overlaps #{hit}, which can't be scanned" if hit
    end

    def status_warnings(roots)
      warnings = []
      warnings << :mounted_read_write if roots.any? { |root| root[:read_only] == false }
      warnings << :whole_home_allowed if filter_blank?
      warnings << :running_as_root if roots.any? { |root| root[:path] == "/root" }
      warnings
    end
  end
end
