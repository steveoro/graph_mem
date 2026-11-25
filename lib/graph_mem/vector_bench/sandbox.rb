# frozen_string_literal: true

module GraphMem
  module VectorBench
    # The scratch database of `graph_mem:vector_bench` (step 1 of
    # docs/plans/mariadb-vector-search-plan.md). For the block it connects the primary connection
    # to a database of its own (default `graph_mem_vector_bench`), created here, loaded from
    # db/structure.sql (ScanProfile::StructureLoader), marked in ar_internal_metadata and dropped at
    # the end (unless keep_db). It refuses production, a non-MariaDB adapter, a name without the
    # `_vector_bench` suffix, the name of any database configured in config/database.yml (any
    # environment), and an existing database it didn't make. Jobs go to the :test adapter, the
    # caches to a private memory store, inline embeddings are suppressed and the SQL log is off:
    # nothing reaches Solid Queue, the app's cache, an embedding endpoint or log/.
    #
    #   Sandbox.new.run do |sandbox|
    #     sandbox.target # => "graph_mem_vector_bench"
    #     # … ActiveRecord::Base.connection is on the scratch database …
    #   end
    class Sandbox
      DEFAULT_TARGET = "graph_mem_vector_bench"
      SUFFIX = "_vector_bench"
      MARKER_KEY = "graph_mem_vector_bench"
      ADAPTERS = %w[mysql2 trilogy].freeze
      STRUCTURE = Rails.root.join("db/structure.sql")

      # Raised when the run may not start, or a write would reach another database.
      class Refused < StandardError; end

      # The server-level connection (no database selected) that checks, creates and drops the
      # scratch database.
      class AdminRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      # @return [String] the scratch database's name
      attr_reader :target

      # @param env [String] the Rails environment
      # @param base_config [ActiveRecord::DatabaseConfigurations::DatabaseConfig] the primary
      #   database's config: its server and credentials are reused, its database is never connected to
      # @param target [String, nil] the scratch database (DB=); default DEFAULT_TARGET
      # @param keep_db [Boolean] keep the database at the end (KEEP_DB=1)
      # @param configured [Array<String>] the names the target must not take (default: every
      #   database in config/database.yml)
      def initialize(env: Rails.env, base_config: ActiveRecord::Base.connection_db_config, target: nil, keep_db: false,
                     configured: ActiveRecord::Base.configurations.configurations.map(&:database))
        @env = env.to_s
        @base_config = base_config
        @target = (target.presence || DEFAULT_TARGET).to_s
        @keep_db = keep_db
        @configured = configured.compact.map(&:to_s)
      end

      # @return [void]
      # @raise [Refused] production, a wrong adapter or name, or a configured database
      def check!
        raise Refused, "graph_mem:vector_bench never runs in production" if @env == "production"
        raise Refused, "graph_mem:vector_bench needs MariaDB (adapter #{@base_config.adapter})" unless ADAPTERS.include?(@base_config.adapter.to_s)
        unless @target.match?(/\A\w+\z/) && @target.end_with?(SUFFIX)
          raise Refused, "the scratch database must be named <name>#{SUFFIX} (got #{@target.inspect})"
        end
        raise Refused, "#{@target} is a database of config/database.yml" if @configured.include?(@target)
      end

      # Runs the block on the scratch database, then restores the connection and drops it.
      #
      # @yieldparam sandbox [Sandbox]
      # @return [Object] the block's value
      # @raise [Refused] see #check!, or a database of that name the bench didn't make
      def run
        check!
        original = ActiveRecord::Base.connection_pool.db_config
        AdminRecord.establish_connection(connection_hash(nil))
        prepare_database!
        isolated do
          ActiveRecord::Base.establish_connection(connection_hash(@target))
          assert_target!
          ScanProfile::StructureLoader.load!(ActiveRecord::Base.connection, STRUCTURE)
          mark!
          yield self
        end
      ensure
        ActiveRecord::Base.establish_connection(original) if original
        finish!
      end

      # Raises unless the primary connection is on the scratch database.
      #
      # @return [void]
      # @raise [Refused]
      def assert_target!
        current = ActiveRecord::Base.connection.current_database
        raise Refused, "refusing to write to #{current.inspect}: the bench only writes to #{@target}" unless current == @target
      end

      private

      def connection_hash(database)
        @base_config.configuration_hash.except(:url, :database).merge(database: database)
      end

      def admin
        AdminRecord.connection
      end

      def prepare_database!
        if admin.select_value("SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = #{admin.quote(@target)}")
          raise Refused, "#{@target} exists and wasn't made by graph_mem:vector_bench; drop it or pass DB=<name>#{SUFFIX}" unless ours?

          admin.execute("DROP DATABASE #{admin.quote_table_name(@target)}")
        end
        admin.execute("CREATE DATABASE #{admin.quote_table_name(@target)} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        @created = true
      end

      def ours?
        admin.select_value("SELECT `value` FROM #{admin.quote_table_name(@target)}.`ar_internal_metadata` WHERE `key` = #{admin.quote(MARKER_KEY)}").present?
      rescue ActiveRecord::StatementInvalid
        false
      end

      def mark!
        connection = ActiveRecord::Base.connection
        connection.execute("INSERT INTO `ar_internal_metadata` (`key`, `value`, `created_at`, `updated_at`) " \
                           "VALUES (#{connection.quote(MARKER_KEY)}, #{connection.quote(GraphMem::VERSION)}, NOW(6), NOW(6))")
      end

      # The SQL log is off too: the seeding statements carry megabytes of vector literals.
      def isolated
        previous = { adapter: ActiveJob::Base.queue_adapter, cache: Rails.cache, settings_cache: RailsSettings.config.cache_storage,
                     logger: ActiveRecord::Base.logger }
        ActiveRecord::Base.logger = nil
        ActiveJob::Base.queue_adapter = :test
        Rails.cache = RailsSettings.config.cache_storage = ActiveSupport::Cache::MemoryStore.new
        reset_memos!
        EmbeddingService.suppress_inline_embeddings { yield }
      ensure
        ActiveRecord::Base.logger = previous[:logger]
        ActiveJob::Base.queue_adapter = previous[:adapter]
        Rails.cache = previous[:cache]
        RailsSettings.config.cache_storage = previous[:settings_cache]
        reset_memos!
      end

      # Class-level memos read from a database: the scratch database's must not outlive the run.
      def reset_memos!
        RailsSettings::RequestCache.reset
        EmbeddingService.reset_vector_cache!
        EmbeddingService.reset_instance!
      end

      def finish!
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
