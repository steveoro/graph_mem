# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # The options of `bin/rails graph_mem:scan_profile` (F-3b), read from the environment and checked
    # before anything runs. Unknown repo keys, profiles, chains and settings are refused.
    #
    #   options = Options.parse(ENV.to_h, manifest: Manifest.load)
    #   options.repos    # => ["synth", "goggles_api"] for REPOS=synth,goggles_api
    #   options.profiles # => ["docs"] for PROFILE=docs
    #   options.chain    # => "ollama" unless BACKEND=…
    #
    # @!attribute repos [Array<String>] REPOS (default: every manifest key, synth first)
    # @!attribute profiles [Array<String>] PROFILE=docs|code (default: both)
    # @!attribute rescan [Boolean] a second, `mode: "rescan"` run per scan (RESCAN=0 turns it off)
    # @!attribute full [Boolean] FULL=1: the scanner's own caps for every repo
    # @!attribute keep_db [Boolean] KEEP_DB=1
    # @!attribute chain [String] BACKEND: the run's llm_chain_scan (an Llm::Chain value)
    # @!attribute allow_cloud [Boolean] ALLOW_CLOUD=1: the scanned projects allow cloud access
    # @!attribute settings [Hash{String => String}] SETTINGS="key=value;…" (summary_* and llm_* fields)
    # @!attribute db [String, nil] DB: the throwaway database's name
    # @!attribute report_dir [String] REPORT_DIR (default tmp/scan_profile)
    Options = Data.define(:repos, :profiles, :rescan, :full, :keep_db, :chain, :allow_cloud, :settings, :db, :report_dir) do
      # Raised for an option value that isn't allowed.
      const_set(:Error, Class.new(StandardError))

      # A settings key SETTINGS may set: the model and provider settings, never the scan chain
      # (BACKEND), budgets or inline cloud tasks.
      const_set(:SETTING_KEY, /\A(summary_\w+|llm_(?!chain_|budget_|inline_)\w+)\z/)

      # @param env [Hash{String => String}]
      # @param manifest [Manifest]
      # @return [Options]
      # @raise [Options::Error]
      def self.parse(env, manifest:)
        new(repos: repos(env["REPOS"], manifest), profiles: list(env["PROFILE"], Manifest::PROFILES, "PROFILE"),
            rescan: env["RESCAN"].to_s != "0", full: env["FULL"].to_s == "1", keep_db: env["KEEP_DB"].to_s == "1",
            chain: chain(env["BACKEND"]), allow_cloud: env["ALLOW_CLOUD"].to_s == "1", settings: settings(env["SETTINGS"]),
            db: env["DB"].presence, report_dir: env["REPORT_DIR"].presence || Rails.root.join("tmp/scan_profile").to_s)
      end

      def self.repos(value, manifest)
        keys = value.to_s.split(",").map(&:strip).reject(&:empty?)
        return manifest.keys if keys.empty?

        keys.uniq.each { |key| manifest.fetch(key) }
      rescue Manifest::Error => e
        raise self::Error, "REPOS: #{e.message}"
      end

      def self.list(value, allowed, name)
        picked = value.to_s.split(",").map(&:strip).reject(&:empty?)
        return allowed.dup if picked.empty?

        unknown = picked - allowed
        raise self::Error, "#{name}: unknown #{unknown.join(', ')} (use #{allowed.join(' or ')})" if unknown.any?

        picked.uniq
      end

      def self.chain(value)
        chain = value.to_s.strip.presence || Llm::Router::DEFAULT_CHAIN
        raise self::Error, "BACKEND: #{chain.inspect} isn't a scan chain (one of #{Llm::Router::CHAIN_VALUES.join(' | ')})" unless Llm::Router::CHAIN_VALUES.include?(chain)

        chain
      end

      def self.settings(value)
        value.to_s.split(";").map(&:strip).reject(&:empty?).to_h do |pair|
          key, setting = pair.split("=", 2).map(&:strip)
          unless key.to_s.match?(self::SETTING_KEY) && AppSettings.respond_to?(:"#{key}=") && !setting.nil?
            raise self::Error, "SETTINGS: #{key.inspect} can't be set here (summary_* and model settings only, as key=value)"
          end

          [ key, setting ]
        end
      end
      private_class_method :repos, :list, :chain, :settings

      # @return [Boolean] the chain names a cloud provider
      def cloud? = Llm::Router::CHAIN_VALUES.include?(chain) && chain != Llm::Router::DEFAULT_CHAIN
    end
  end
end
