# frozen_string_literal: true

class ScanRootPolicy
  # Parses and validates the runtime subfolder filter (`AppSettings.project_scan_subfolders`,
  # mcp plan PR-0 §0.2): a comma/newline-separated list of paths relative to the scan root.
  module Subfolders
    MAX_ENTRIES = 20
    MAX_ENTRY_LENGTH = 512

    module_function

    # @param raw [String, nil] the setting value
    # @param hard_roots [Array<String>] real paths of the hard roots, used to turn an absolute
    #   entry into a relative one
    # @return [Array<Hash>] one +{ input:, path:, error: }+ per entry; +path+ is relative and
    #   +error+ a message when the entry is rejected
    def parse(raw, hard_roots: [])
      entries = split(raw).map { |input| parse_entry(input, hard_roots) }
      entries.each_with_index.map do |entry, index|
        index < MAX_ENTRIES ? entry : entry.merge(error: "at most #{MAX_ENTRIES} entries are allowed")
      end
    end

    # @return [Array<String>] the stripped, non-blank entries of +raw+
    def split(raw)
      raw.to_s.split(/[\r\n,]+/).map(&:strip).reject(&:empty?)
    end

    # @return [String] the entries joined the way they're stored
    def join(entries)
      entries.join(", ")
    end

    def parse_entry(input, hard_roots)
      return { input: input, path: nil, error: "is longer than #{MAX_ENTRY_LENGTH} characters" } if input.length > MAX_ENTRY_LENGTH

      relative = relativize(input, hard_roots)
      return { input: input, path: nil, error: "is outside the scan root" } if relative.nil?

      { input: input, path: relative, error: entry_error(relative) }
    end

    # Absolute entries under a hard root become relative; other absolute entries are rejected (nil).
    def relativize(input, hard_roots)
      return input.delete_suffix("/") unless input.start_with?("/")

      root = hard_roots.find { |candidate| ScanRootPolicy.contained?(candidate, input.delete_suffix("/")) }
      return nil unless root

      input.delete_suffix("/").delete_prefix(root).delete_prefix("/").presence || "."
    end

    def entry_error(relative)
      return nil if relative == "."

      segments = relative.split("/", -1)
      return "contains '..'" if segments.include?("..")
      return "has an empty path segment" if segments.any?(&:empty?)

      denied = segments.find { |segment| Denylist.root_segment_denied?(segment) }
      "is inside a hidden or protected folder (#{denied})" if denied
    end
  end
end
