# frozen_string_literal: true

class ScanRootPolicy
  # Reads /proc/self/mountinfo (container mode only) to tell whether a hard root is a mount
  # point and whether it is mounted read-only (mcp plan PR-0 §0.1).
  module Mounts
    DEFAULT_MOUNTINFO = "/proc/self/mountinfo"

    module_function

    # @param path [String] an absolute path
    # @param mountinfo_path [String] the mountinfo file (overridable for specs)
    # @return [Hash, nil] +{ read_only: Boolean }+ when +path+ is a mount point, nil otherwise
    def lookup(path, mountinfo_path: DEFAULT_MOUNTINFO)
      entry = entries(mountinfo_path).reverse.find { |mount| mount[:mount_point] == path }
      entry && { read_only: entry[:options].include?("ro") }
    end

    # @return [Array<Hash>] +{ mount_point:, options: }+ per line; [] when the file can't be read
    def entries(mountinfo_path)
      File.readlines(mountinfo_path, chomp: true).filter_map do |line|
        fields = line.split(" ")
        next if fields.size < 6

        { mount_point: unescape(fields[4]), options: fields[5].split(",") }
      end
    rescue SystemCallError
      []
    end

    # mountinfo escapes spaces, tabs, newlines and backslashes as octal (\040 …).
    def unescape(field)
      field.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
    end
  end
end
