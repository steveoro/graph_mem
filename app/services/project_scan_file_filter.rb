# frozen_string_literal: true

# Keeps project scans inside their root (mcp plan PR-0 §0.5 item 5): rejects file_globs that are
# absolute or contain "..", drops files whose realpath leaves the root, and drops denylisted
# files (ScanRootPolicy.denied_file?) even when a glob names them explicitly.
#
# When the project folder is a home folder (ScanRootPolicy.home_folder?), its top-level hidden and
# protected entries (~/.config, ~/.bash_history, ~/Library, …) belong to the home rather than to
# a project, so they are never read either. ScanRootPolicy.resolve already refuses a home as a
# project folder; this is the second layer.
#
# @example
#   filter = ProjectScanFileFilter.new("/home/steve/Projects/foo")
#   filter.invalid_glob(["../x/*"]) # => "../x/*"
#   files = filter.glob("**/*.rb").filter_map { |path| filter.kept_path(path) }
#   filter.counters # => { "skipped_outside_root" => 1, "skipped_denylisted" => 2 }
class ProjectScanFileFilter
  PARENT_SEGMENT = %r{(\A|[/{,])\.\.(\z|[/},])}

  attr_reader :root, :counters

  # @param project_root [String] the project folder (resolved to its realpath when it exists)
  def initialize(project_root)
    @root = ScanRootPolicy.realpath_or_nil(project_root) || File.expand_path(project_root)
    @root_is_home = ScanRootPolicy.home_folder?(@root)
    @counters = { "skipped_outside_root" => 0, "skipped_denylisted" => 0 }
  end

  # @param globs [Array<String>]
  # @return [String, nil] the first glob that is absolute or has a ".." segment (braces included)
  def invalid_glob(globs)
    Array(globs).map(&:to_s).find { |glob| glob.start_with?("/", "~") || glob.match?(PARENT_SEGMENT) }
  end

  # Globs relative to the root, so metacharacters in the root's own name are never patterns.
  #
  # @return [Array<String>] absolute paths
  def glob(pattern)
    Dir.glob(pattern, base: @root).map { |relative| File.join(@root, relative) }
  end

  # @param path [String] a path found by globbing under the root
  # @return [String, nil] the realpath to read, or nil (counting the reason) when it may not be read
  def kept_path(path)
    real = ScanRootPolicy.realpath_or_nil(path)
    return skip("skipped_outside_root") unless real && ScanRootPolicy.contained?(@root, real)
    return skip("skipped_denylisted") if ScanRootPolicy.denied_file?(@root, path) || root_level_denied?(path, real)

    real
  end

  # @return [Boolean] whether +path+ may be read
  def keep?(path)
    !kept_path(path).nil?
  end

  private

  def root_level_denied?(path, real)
    @root_is_home && [ path, real ].any? do |candidate|
      next false unless ScanRootPolicy.contained?(@root, candidate)

      first = ScanRootPolicy.relative_to(@root, candidate).split("/").first.to_s
      ScanRootPolicy::Denylist.root_segment_denied?(first)
    end
  end

  def skip(counter)
    @counters[counter] += 1
    nil
  end
end
