# frozen_string_literal: true

# Shared by the dashboard scan forms: resolve the typed path through ScanRootPolicy and word its
# warnings for a flash message.
module ScanRootResolution
  WARNING_TEXTS = {
    mounted_read_write: "the scan folder is mounted read-write; mount it with :ro",
    whole_home_allowed: "the subfolder filter is blank, so the whole home folder is scannable",
    running_as_root: "graph_mem is running as root"
  }.freeze

  # @param result [ScanRootPolicy::Result]
  # @return [String] " Warning: …" for the result's warnings, or ""
  def self.warning_suffix(result)
    texts = Array(result.warnings).map { |warning| WARNING_TEXTS.fetch(warning, warning.to_s) }
    texts.empty? ? "" : " Warning: #{texts.join('; ')}."
  end

  private

  # @return [ScanRootPolicy::Result]
  def resolve_scan_root(input)
    ScanRootPolicy.resolve(input)
  end

  def scan_root_warning_suffix(result)
    ScanRootResolution.warning_suffix(result)
  end
end
