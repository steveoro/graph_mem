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
      .pgpass .my.cnf .*_history .htpasswd .s3cfg *.ovpn
    ].freeze

    module_function

    # @param segment [String] one path segment
    # @return [Boolean] true when the segment can't be part of a scan root
    def root_segment_denied?(segment)
      segment.start_with?(".") || ROOT_SEGMENTS.any? { |denied| denied.casecmp?(segment) }
    end

    # Dot-segments are denied at any depth; the protected home-level names (ROOT_SEGMENTS) only as
    # the first segment below the root, so a project called "library" or "snap" is fine.
    #
    # @param relative_path [String] a path relative to a hard root
    # @return [Boolean] true when the path can't be (or be inside) a scan root
    def root_path_denied?(relative_path)
      segments = relative_path.split("/")
      segments.any? { |segment| segment.start_with?(".") } || root_segment_denied?(segments.first.to_s)
    end

    # Case-insensitive: secrets don't need exact case, and some filesystems ignore it.
    #
    # @param relative_path [String] a file path relative to the project root
    # @return [Boolean] true when the file must never be read
    def file_denied?(relative_path)
      segments = relative_path.split("/")
      return true if segments[0...-1].any? { |segment| FILE_DIR_SEGMENTS.any? { |denied| denied.casecmp?(segment) } }

      basename = segments.last.to_s
      FILE_PATTERNS.any? { |pattern| File.fnmatch?(pattern, basename, File::FNM_DOTMATCH | File::FNM_CASEFOLD) }
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
