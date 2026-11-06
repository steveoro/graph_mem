# frozen_string_literal: true

require "yaml"

module GraphMem
  module ScanProfile
    # The fixture repos of `graph_mem:scan_profile` (F-3b), read from script/scan_profile/repos.yml
    # and checked: every entry is a public GitHub repo over https, pinned by a full commit SHA, with
    # a license and both profiles. The generated repos are always available too: `synth` (SynthRepo)
    # and `synth_rails` (SynthRailsRepo, 1.75.0: the Rails code map's fixture).
    #
    #   manifest = GraphMem::ScanProfile::Manifest.load
    #   manifest.keys                    # => ["synth", "synth_rails", "graph_mem", "goggles_db", "goggles_api", "dry-inflector"]
    #   repo = manifest.fetch("goggles_api")
    #   repo.globs("code")               # => ["app/api/**/*.rb"]
    #   manifest.caps(repo, full: false) # => { max_total_input_bytes: 65536, max_files: 20 }
    class Manifest
      # Raised for a manifest entry or a REPOS key that isn't allowed.
      class Error < StandardError; end

      PATH = Rails.root.join("script/scan_profile/repos.yml")
      PROFILES = %w[docs code].freeze
      URL_FORMAT = %r{\Ahttps://github\.com/[A-Za-z0-9][\w.-]*/[\w.-]+\.git\z}
      COMMIT_FORMAT = /\A\h{40}\z/
      KEY_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/
      # The generated repos, by key: each writes its files, its expected lists and its stub answers.
      SYNTHETIC = { SynthRepo::KEY => SynthRepo, SynthRailsRepo::KEY => SynthRailsRepo }.freeze

      # One fixture repo.
      #
      # @!attribute key [String] the REPOS key
      # @!attribute url [String, nil] the clone URL (nil for synth)
      # @!attribute commit [String, nil] the pinned SHA (nil for synth)
      # @!attribute license [String, nil]
      # @!attribute project_name [String]
      # @!attribute full [Boolean] always the scanner's own caps
      # @!attribute exclude [Array<String>] globs deleted from the clone before scanning
      # @!attribute profiles [Hash{String => Array<String>}] the globs per profile
      Repo = Data.define(:key, :url, :commit, :license, :project_name, :full, :exclude, :profiles) do
        # @return [Boolean] a generated repo (Manifest::SYNTHETIC)
        def synth? = url.nil?

        # @param profile [String] "docs" or "code"
        # @return [Array<String>, nil] the profile's globs; nil when the repo has no such profile
        def globs(profile) = profiles[profile]
      end

      # @param key [String]
      # @return [Module, nil] the generated repo of that key (SynthRepo, SynthRailsRepo), nil for a pinned repo
      def self.synthetic(key) = SYNTHETIC[key.to_s]

      # @param path [String, Pathname]
      # @return [Manifest]
      # @raise [Error] for an entry that isn't allowed
      def self.load(path = PATH)
        new(YAML.safe_load_file(path.to_s, permitted_classes: [], aliases: false))
      end

      # @param data [Hash] the parsed YAML
      # @raise [Error] for an entry that isn't allowed
      def initialize(data)
        raise Error, "the manifest must be a mapping with a `repos` mapping" unless data.is_a?(Hash) && data["repos"].is_a?(Hash)

        @first_run_caps = parse_caps(data["first_run_caps"])
        @repos = SYNTHETIC.transform_values(&:manifest_repo)
        data["repos"].each { |key, entry| @repos[key.to_s] = parse_repo(key.to_s, entry) }
      end

      # @return [Array<String>] the generated repos first, then the manifest's order
      def keys = @repos.keys

      # @param key [String]
      # @return [Repo]
      # @raise [Error] for a key that isn't in the manifest or synth
      def fetch(key)
        @repos.fetch(key.to_s) { raise Error, "unknown repo #{key.to_s.inspect}: use one of #{keys.join(', ')}" }
      end

      # The caps passed to ProjectScanner.new: the first-run caps, or nils (the scanner's own) when
      # the run or the repo is full.
      #
      # @param repo [Repo]
      # @param full [Boolean] FULL=1
      # @return [Hash{Symbol => Integer, nil}] `{ max_total_input_bytes:, max_files: }`
      def caps(repo, full:)
        full || repo.full ? { max_total_input_bytes: nil, max_files: nil } : @first_run_caps
      end

      private

      def parse_caps(caps)
        raise Error, "first_run_caps needs max_total_input_bytes and max_files" unless caps.is_a?(Hash)

        { max_total_input_bytes: positive(caps["max_total_input_bytes"], "max_total_input_bytes"),
          max_files: positive(caps["max_files"], "max_files") }
      end

      def positive(value, name)
        Integer(value).tap { |number| raise Error, "#{name} must be positive" unless number.positive? }
      rescue ArgumentError, TypeError
        raise Error, "#{name} must be an integer"
      end

      def parse_repo(key, entry)
        raise Error, "repo #{key.inspect}: the key must match #{KEY_FORMAT.source}" unless key.match?(KEY_FORMAT) && !SYNTHETIC.key?(key)
        raise Error, "repo #{key}: the entry must be a mapping" unless entry.is_a?(Hash)

        url = entry["url"].to_s
        raise Error, "repo #{key}: url must be a public https://github.com/<owner>/<repo>.git URL" unless url.match?(URL_FORMAT)
        raise Error, "repo #{key}: commit must be a full 40-character SHA" unless entry["commit"].to_s.match?(COMMIT_FORMAT)
        raise Error, "repo #{key}: license is required (open-source repos only)" if entry["license"].to_s.strip.empty?

        Repo.new(key: key, url: url, commit: entry["commit"].to_s.downcase, license: entry["license"].to_s,
                 project_name: entry["project_name"].to_s.strip.presence || key, full: entry["full"] == true,
                 exclude: globs_list(key, "exclude", entry["exclude"] || []), profiles: parse_profiles(key, entry["profiles"]))
      end

      def parse_profiles(key, profiles)
        raise Error, "repo #{key}: profiles must define #{PROFILES.join(' and ')}" unless profiles.is_a?(Hash) && (PROFILES - profiles.keys).empty?

        PROFILES.index_with do |profile|
          value = profiles[profile]
          value == "default" ? ProjectScanner::DEFAULT_FILE_GLOBS.dup : globs_list(key, profile, value)
        end
      end

      def globs_list(key, name, value)
        list = Array(value).map(&:to_s)
        bad = list.find { |glob| glob.start_with?("/", "~") || glob.match?(ProjectScanFileFilter::PARENT_SEGMENT) }
        raise Error, "repo #{key}: #{name} entry #{bad.inspect} must be relative, without '..'" if bad
        raise Error, "repo #{key}: #{name} must be a list of globs" if name != "exclude" && list.empty?

        list
      end
    end
  end
end
