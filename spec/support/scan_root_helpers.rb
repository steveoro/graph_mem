# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Synthetic scan homes for ScanRootPolicy (mcp plan PR-0 §0.8): specs never resolve real folders.
#
# Every example runs with GRAPH_MEM_SCAN_ROOTS pointing at an empty sandbox, so the native
# fallback (Dir.home) can't make a real ~/Projects scannable. `with_scan_home` swaps in a fresh
# home with a Projects/ folder for the block.
module ScanRootHelpers
  SCAN_ENV_KEYS = %w[GRAPH_MEM_SCAN_ROOTS GRAPH_MEM_IN_CONTAINER GRAPH_MEM_SCANS].freeze
  SANDBOX = File.realpath(Dir.mktmpdir("scan_sandbox"))
  at_exit { FileUtils.remove_entry(SANDBOX) if File.directory?(SANDBOX) }

  # @param subfolders [String] the subfolder filter to store ("" = whole home)
  # @param container [Boolean] run in container mode (needs +mountinfo:+ to see a mount)
  # @param mountinfo [String, nil] mountinfo text; "%{home}" is replaced by the home path
  # @yieldparam home [String] the real path of the synthetic home
  def with_scan_home(subfolders: "Projects", container: false, mountinfo: nil)
    Dir.mktmpdir("scan_home") do |dir|
      home = File.realpath(dir)
      FileUtils.mkdir_p(File.join(home, "Projects"))
      ENV["GRAPH_MEM_SCAN_ROOTS"] = home
      container ? ENV["GRAPH_MEM_IN_CONTAINER"] = "1" : ENV.delete("GRAPH_MEM_IN_CONTAINER")
      write_mountinfo(home, mountinfo) if mountinfo
      AppSettings.project_scan_subfolders = subfolders
      yield home
    end
  end

  # A synthetic project folder at <home>/Projects/<name>, with one source file.
  #
  # @yieldparam project [String] the project's real path
  # @yieldparam home [String] the synthetic home
  def with_scan_project(name = "demo", **home_options)
    with_scan_home(**home_options) do |home|
      project = File.join(home, "Projects", name)
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "README.md"), "# SynthWidget\n")
      yield project, home
    end
  end

  # Stores the subfolder filter row directly, the way another process would.
  def write_scan_subfolders_raw(value)
    AppSettings.project_scan_subfolders = value
  end

  private

  def write_mountinfo(home, text)
    file = File.join(home, ".mountinfo_fixture")
    File.write(file, format(text, home: home.gsub(" ", "\\\\040")))
    ScanRootPolicy.mountinfo_path = file
  end
end

RSpec.configure do |config|
  config.include ScanRootHelpers

  config.around do |example|
    saved = ScanRootHelpers::SCAN_ENV_KEYS.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    ENV["GRAPH_MEM_SCAN_ROOTS"] = ScanRootHelpers::SANDBOX
    ENV.delete("GRAPH_MEM_IN_CONTAINER")
    ENV.delete("GRAPH_MEM_SCANS")
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    ScanRootPolicy.mountinfo_path = nil
  end
end
