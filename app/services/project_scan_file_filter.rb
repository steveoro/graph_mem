# frozen_string_literal: true

# Keeps project scans inside their root (mcp plan PR-0 §0.5 item 5): rejects file_globs that are
# absolute or contain "..", drops files whose realpath leaves the root, and drops denylisted
# files (ScanRootPolicy.denied_file?) even when a glob names them explicitly.
#
# @example
#   filter = ProjectScanFileFilter.new("/home/steve/Projects/foo")
#   filter.invalid_glob(["../x/*"]) # => "../x/*"
#   files = paths.select { |path| filter.keep?(path) }
#   filter.counters # => { "skipped_outside_root" => 1, "skipped_denylisted" => 2 }
class ProjectScanFileFilter
  attr_reader :root, :counters

  # @param project_root [String] the project folder (resolved to its realpath when it exists)
  def initialize(project_root)
    @root = ScanRootPolicy.realpath_or_nil(project_root) || File.expand_path(project_root)
    @counters = { "skipped_outside_root" => 0, "skipped_denylisted" => 0 }
  end

  # @param globs [Array<String>]
  # @return [String, nil] the first glob that is absolute or has a ".." segment
  def invalid_glob(globs)
    Array(globs).find { |glob| glob.to_s.start_with?("/", "~") || glob.to_s.split("/").include?("..") }
  end

  # @param path [String] a path found by globbing under the root
  # @return [Boolean] true when the file may be read; counts the reason when it may not
  def keep?(path)
    real = ScanRootPolicy.realpath_or_nil(path)
    return skip("skipped_outside_root") unless real && ScanRootPolicy.contained?(@root, real)
    return skip("skipped_denylisted") if ScanRootPolicy.denied_file?(@root, path)

    true
  end

  private

  def skip(counter)
    @counters[counter] += 1
    false
  end
end
