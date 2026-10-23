# frozen_string_literal: true

class ScanRootPolicy
  # Hard, non-overridable denylist (mcp plan PR-0 §0.3). Constants, not settings.
  module Denylist
    # Folder names that can never be (or contain) a scan root, besides any segment starting with ".".
    ROOT_SEGMENTS = %w[snap Library AppData Maildir Mail].freeze

    # Directory segments whose contents are never read inside a project.
    FILE_DIR_SEGMENTS = %w[.git .ssh .gnupg .aws .kube .docker .password-store].freeze

    # File name patterns that are never read inside a project, even via explicit file_globs.
    FILE_PATTERNS = %w[
      .env .env.* *.pem *.key *.p12 *.pfx *.jks *.keystore *.kdbx
      id_rsa* id_dsa* id_ecdsa* id_ed25519* .netrc .npmrc .pypirc .git-credentials
      credentials credentials.* master.key *.tfstate *.tfstate.*
    ].freeze

    module_function

    # @param segment [String] one path segment
    # @return [Boolean] true when the segment can't be part of a scan root
    def root_segment_denied?(segment)
      segment.start_with?(".") || ROOT_SEGMENTS.include?(segment)
    end

    # @param relative_path [String] a path relative to a hard root
    # @return [Boolean] true when any segment is denied for scan roots
    def root_path_denied?(relative_path)
      relative_path.split("/").any? { |segment| root_segment_denied?(segment) }
    end

    # @param relative_path [String] a file path relative to the project root
    # @return [Boolean] true when the file must never be read
    def file_denied?(relative_path)
      segments = relative_path.split("/")
      return true if segments[0...-1].any? { |segment| FILE_DIR_SEGMENTS.include?(segment) }

      basename = segments.last.to_s
      FILE_PATTERNS.any? { |pattern| File.fnmatch?(pattern, basename, File::FNM_DOTMATCH) }
    end

    # @return [Hash] the lists, for display (Settings › Project scans "Always blocked")
    def to_h
      {
        root_folders: [ "any folder whose name starts with \".\"" ] + ROOT_SEGMENTS,
        file_folders: FILE_DIR_SEGMENTS,
        files: FILE_PATTERNS
      }
    end
  end
end
