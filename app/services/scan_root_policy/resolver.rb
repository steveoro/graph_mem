# frozen_string_literal: true

class ScanRootPolicy
  # Implements ScanRootPolicy.resolve (mcp plan PR-0 §0.4, steps 1-12). Each step returns its
  # own code with an actionable message.
  class Resolver
    def initialize(policy)
      @policy = policy
    end

    # @param input [String, nil]
    # @return [ScanRootPolicy::Result]
    def call(input)
      return failure(:disabled, "Project scans are disabled (GRAPH_MEM_SCANS=off).") unless @policy.enabled?

      @roots = @policy.valid_hard_roots
      return not_configured if @roots.empty?

      path = input.to_s.strip
      lexical_checks(path) || filesystem_checks(path)
    end

    private

    def lexical_checks(path)
      return failure(:blank, "Give the path of the project folder to scan.") if path.empty?
      return failure(:invalid, "The path is not valid.") if path.include?("\0") || path.length > MAX_INPUT_LENGTH
      return failure(:invalid, "Use a path without '..'.") if path.split("/").include?("..")

      @path = absolutize(path)
      return @path if @path.is_a?(Result)

      @path = @policy.map_host_path(@path)
      @root = @roots.find { |root| [ root[:path], root[:configured] ].any? { |base| @policy.contained?(base, @path) } }
      return not_mounted unless @root

      base = [ @root[:path], @root[:configured] ].find { |candidate| @policy.contained?(candidate, @path) }
      denied(@path) if Denylist.root_path_denied?(@policy.relative_to(base, @path))
    end

    def filesystem_checks(_path)
      real = realpath(@path)
      return real if real.is_a?(Result)
      return failure(:outside_roots, "#{@path} resolves outside #{@root[:path]} (through a symlink).") unless @policy.contained?(@root[:path], real)
      return denied(real) if Denylist.root_path_denied?(@policy.relative_to(@root[:path], real))
      if @policy.home_folder?(real)
        return failure(:whole_root, "#{real} is a home folder; pick a project folder inside it.")
      end

      return outside_filter(real) unless @policy.allowed_roots.any? { |allowed| @policy.contained?(allowed[:path], real) }
      return failure(:not_directory, "#{real} is not a directory.") unless File.directory?(real)
      return not_readable(real) unless File.readable?(real) && File.executable?(real)

      Result.new(ok: true, path: real, root: @root[:path], code: :ok, message: "#{real} can be scanned.",
                 warnings: warnings)
    end

    # Step 4: "~" means the single hard root; a relative path resolves against the single allowed root.
    def absolutize(path)
      if path == "~" || path.start_with?("~/")
        return failure(:invalid, "Give the full path: more than one scan root is configured.") unless @roots.one?

        return File.join(@roots.first[:path], path.delete_prefix("~").delete_prefix("/")).delete_suffix("/")
      end
      return path.delete_suffix("/").presence || "/" if path.start_with?("/")

      allowed = @policy.allowed_roots
      return failure(:invalid, "Give the full path (it starts with /).") unless allowed.one?

      File.join(allowed.first[:path], path).delete_suffix("/")
    end

    def realpath(path)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      parent = File.dirname(path)
      hint = File.directory?(parent) ? "its parent #{parent} exists" : "its parent #{parent} doesn't exist either"
      failure(:not_found, "#{path} was not found (#{hint}).")
    rescue Errno::EACCES
      not_readable(path)
    end

    def warnings
      warnings = []
      warnings << :mounted_read_write if @root[:read_only] == false
      warnings << :whole_home_allowed if @policy.filter_blank?
      warnings << :running_as_root if @root[:path] == "/root"
      warnings
    end

    def not_configured
      if @policy.container?
        failure(:not_configured, "Scans are disabled: nothing is mounted for graph_mem to read. Add the volume line " \
                                 "#{COMPOSE_VOLUME_LINE} to the app service (see docs/container_scan_mounts.md).")
      else
        failure(:not_configured, "No usable scan root: set GRAPH_MEM_SCAN_ROOTS to an existing folder.")
      end
    end

    def not_mounted
      visible = @roots.map { |root| root[:path] }.join(", ")
      failure(:not_mounted, "#{@path} isn't visible to graph_mem: only #{visible} is.")
    end

    def denied(path)
      failure(:denied, "#{path} is inside a hidden or protected folder; this can't be enabled.")
    end

    def outside_filter(real)
      folder = @policy.relative_to(@root[:path], real).split("/").first.to_s
      filter = Subfolders.split(AppSettings.project_scan_subfolders_raw).join(", ")
      hint = folder.empty? ? "Blank the filter" : "Add #{folder}"
      failure(:outside_filter, "#{real} is outside the scan filter (#{filter}). #{hint} in Settings › Project scans.")
    end

    def not_readable(path)
      hint = @policy.container? ? " The app runs as uid 1000: grant it read access (see docs/container_scan_mounts.md)." : ""
      failure(:not_readable, "#{path} can't be read.#{hint}")
    end

    def failure(code, message)
      Result.new(ok: false, path: nil, root: @root&.fetch(:path, nil), code: code, message: message, warnings: [])
    end
  end
end
