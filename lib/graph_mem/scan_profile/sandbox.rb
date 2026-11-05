# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # The safety guards of `graph_mem:scan_profile` (F-3b, step S). For the block it:
    # - connects the primary database to a throwaway one, `<configured name>_scan_profile`, created
    #   here, loaded from db/structure.sql, marked in ar_internal_metadata and dropped at the end
    #   (unless keep_db); the configured database is never connected to;
    # - runs jobs on the :test adapter (nothing reaches Solid Queue; #enqueued counts them);
    # - gives Rails.cache and the settings cache a private memory store (the run's settings and
    #   LLM usage counters never reach the app's cache), and skips inline embeddings.
    # It refuses production, a target without the suffix (or the configured name itself), a
    # non-MariaDB adapter, and an existing database the profiler didn't make.
    #
    #   Sandbox.new(keep_db: false).run do |sandbox|
    #     sandbox.configure!(chain: "ollama")
    #     sandbox.project!(name: "Gadget Project", root: "/tmp/…/synth", allow_cloud: false)
    #     # … ProjectScanner.new(…).call writes to graph_mem_scan_profile …
    #   end
    class Sandbox
      SUFFIX = "_scan_profile"
      MARKER_KEY = "graph_mem_scan_profile"
      ADAPTERS = %w[mysql2 trilogy].freeze
      # Tables reset_graph! keeps between runs.
      KEPT_TABLES = %w[ar_internal_metadata schema_migrations settings].freeze
      STRUCTURE = Rails.root.join("db/structure.sql")

      # Raised when the run may not start (or a write would reach another database).
      class Refused < StandardError; end

      # The server-level connection (no database selected) that checks, creates and drops the
      # throwaway database.
      class AdminRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      # @return [String] the throwaway database's name
      attr_reader :target

      # @param env [String] the Rails environment
      # @param base_config [ActiveRecord::DatabaseConfigurations::DatabaseConfig] the primary
      #   database's config, whose name the target is derived from (never connected to here)
      # @param target [String, nil] the throwaway database (DB=); default `<configured name>_scan_profile`
      # @param keep_db [Boolean] keep the database at the end (KEEP_DB=1)
      def initialize(env: Rails.env, base_config: ActiveRecord::Base.connection_db_config, target: nil, keep_db: false)
        @env = env.to_s
        @base_config = base_config
        @target = (target.presence || "#{base_config.database}#{SUFFIX}").to_s
        @keep_db = keep_db
      end

      # @return [void]
      # @raise [Refused] production, a wrong adapter, or a target without the suffix
      def check!
        raise Refused, "graph_mem:scan_profile never runs in production" if @env == "production"
        raise Refused, "graph_mem:scan_profile needs MariaDB (adapter #{@base_config.adapter})" unless ADAPTERS.include?(@base_config.adapter.to_s)
        unless @target.match?(/\A\w+\z/) && @target.end_with?(SUFFIX) && @target.length > SUFFIX.length
          raise Refused, "the throwaway database must be named <name>#{SUFFIX} (got #{@target.inspect})"
        end
        raise Refused, "#{@target} is the configured database" if @target == @base_config.database.to_s
      end

      # Runs the block against the throwaway database, then restores the connection and drops it.
      #
      # @yieldparam sandbox [Sandbox]
      # @return [Object] the block's value
      # @raise [Refused] see #check!, or a foreign database with the target's name
      def run
        check!
        original = ActiveRecord::Base.connection_pool.db_config
        AdminRecord.establish_connection(connection_hash(nil))
        prepare_database!
        isolated do
          ActiveRecord::Base.establish_connection(connection_hash(@target))
          assert_target!
          StructureLoader.load!(ActiveRecord::Base.connection, STRUCTURE)
          mark!
          yield self
        end
      ensure
        ActiveRecord::Base.establish_connection(original) if original
        finish!
      end

      # Raises unless the primary connection is on the throwaway database.
      #
      # @return [void]
      # @raise [Refused]
      def assert_target!
        current = ActiveRecord::Base.connection.current_database
        raise Refused, "refusing to write to #{current.inspect}: the profiler only writes to #{@target}" unless current == @target
      end

      # The run's LLM and scan settings, in the throwaway database only.
      #
      # @param chain [String] the scan chain (an Llm::Chain value; "ollama" by default)
      # @param settings [Hash{String => Object}] extra settings (SETTINGS=)
      # @return [void]
      def configure!(chain:, settings: {})
        assert_target!
        AppSettings.enable_llm_summarization = true
        AppSettings.llm_chain_scan = chain
        settings.each { |key, value| AppSettings.public_send(:"#{key}=", value) }
      end

      # The scan's Project root, made before the scan so Llm::CloudGate can find it: cloud access
      # only with allow_cloud (ALLOW_CLOUD=1), for this checkout's folder only.
      #
      # @param name [String]
      # @param root [String] the checkout's realpath
      # @param allow_cloud [Boolean]
      # @return [MemoryEntity]
      def project!(name:, root:, allow_cloud:)
        assert_target!
        MemoryEntity.create!(name: name, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE,
                             cloud_allowed: allow_cloud == true, cloud_root: (root if allow_cloud == true))
      end

      # Empties the graph between runs (every table but KEPT_TABLES).
      #
      # @return [void]
      def reset_graph!
        assert_target!
        connection = ActiveRecord::Base.connection
        connection.execute("SET FOREIGN_KEY_CHECKS = 0")
        (connection.tables - KEPT_TABLES).each { |table| connection.execute("TRUNCATE TABLE #{connection.quote_table_name(table)}") }
      ensure
        connection&.execute("SET FOREIGN_KEY_CHECKS = 1")
      end

      # @return [Hash{String => Integer}] the jobs enqueued so far, per class (none ran)
      def enqueued
        Array(@jobs&.enqueued_jobs).each_with_object(Hash.new(0)) { |job, counts| counts[(job[:job] || job["job_class"]).to_s] += 1 }
      end

      # @return [Hash] the run's LLM usage counters (Llm::Usage, from the private cache)
      def llm_usage
        [ @started_on, Llm::Budget.today ].uniq.each_with_object({}) { |day, usage| usage.deep_merge!(Llm::Usage.day(day)) { |_, a, b| a + b } }
      end

      # @return [Boolean] the database is kept at the end
      def keep_db? = @keep_db == true

      private

      def connection_hash(database)
        @base_config.configuration_hash.except(:url, :database).merge(database: database)
      end

      def admin
        AdminRecord.connection
      end

      def exists?
        admin.select_value("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{admin.quote(@target)}").present?
      end

      def ours?
        admin.select_value("SELECT `value` FROM #{admin.quote_table_name(@target)}.`ar_internal_metadata` WHERE `key` = #{admin.quote(MARKER_KEY)}").present?
      rescue ActiveRecord::StatementInvalid
        false
      end

      def prepare_database!
        if exists?
          raise Refused, "#{@target} exists and wasn't made by graph_mem:scan_profile; drop it or pass another DB=<name>#{SUFFIX}" unless ours?

          Rails.logger.info("[scan_profile] dropping the leftover #{@target}")
          admin.execute("DROP DATABASE #{admin.quote_table_name(@target)}")
        end
        admin.execute("CREATE DATABASE #{admin.quote_table_name(@target)} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        @created = true
      end

      def mark!
        connection = ActiveRecord::Base.connection
        connection.execute("INSERT INTO `ar_internal_metadata` (`key`, `value`, `created_at`, `updated_at`) " \
                           "VALUES (#{connection.quote(MARKER_KEY)}, #{connection.quote(GraphMem::VERSION)}, NOW(6), NOW(6))")
      end

      def isolated
        previous = { adapter: ActiveJob::Base.queue_adapter, cache: Rails.cache, settings_cache: RailsSettings.config.cache_storage }
        ActiveJob::Base.queue_adapter = :test
        @jobs = ActiveJob::Base.queue_adapter
        Rails.cache = RailsSettings.config.cache_storage = ActiveSupport::Cache::MemoryStore.new
        reset_memos!
        @started_on = Llm::Budget.today
        EmbeddingService.suppress_inline_embeddings { yield }
      ensure
        ActiveJob::Base.queue_adapter = previous[:adapter]
        Rails.cache = previous[:cache]
        RailsSettings.config.cache_storage = previous[:settings_cache]
        reset_memos!
      end

      # Class-level memos of database rows: the throwaway database's must not outlive the run.
      def reset_memos!
        RailsSettings::RequestCache.reset
        EntityTypeMapping.reset_canonicalize_cache!
        RelationTypeMapping.reset_canonicalize_cache!
      end

      def finish!
        return unless AdminRecord.connected? || @created

        if @created && !@keep_db
          admin.execute("DROP DATABASE IF EXISTS #{admin.quote_table_name(@target)}")
          @created = false
        end
      ensure
        AdminRecord.remove_connection
      end
    end
  end
end
