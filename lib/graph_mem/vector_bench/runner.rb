# frozen_string_literal: true

module GraphMem
  module VectorBench
    # `graph_mem:vector_bench`, step 1 of docs/plans/mariadb-vector-search-plan.md: seeds the
    # synthetic Fixture into the scratch database (Sandbox) and measures, as Markdown for a PR body:
    # - search latency, p50/p95 per channel: today's exact queries (the real VectorSearchStrategy and
    #   EntityMergeEvidence calls, and suggest_merges' per-entity query) and the raw index shape
    #   (`ORDER BY VEC_DISTANCE_COSINE(...) LIMIT n`), with whether EXPLAIN shows the index;
    # - recall@k of the raw index shape against exact, and the rows a one-type filter keeps;
    # - write cost: single-row inserts and embedding writes (EmbeddingService#store_vector's UPDATE),
    #   rows/s and p50/p95, with the VECTOR KEYs and again after EmbeddingIndexManager.drop_indexes!.
    # The VECTOR KEYs and triggers are installed by EmbeddingIndexManager (embeddings:add_indexes).
    #
    #   GraphMem::VectorBench::Runner.new(Runner::Options.from_env(ENV)).call # => "## Vector bench …"
    class Runner
      # The run's knobs, from ENV (see the rake task's description).
      Options = Struct.new(:rows, :observations, :clusters, :probes, :writes, :k, :seed, :target, :keep_db, keyword_init: true) do
        # @param env [Hash{String => String}]
        # @return [Options]
        # @raise [ArgumentError] a value that isn't a positive integer
        def self.from_env(env)
          number = ->(key, default) { Integer(env.fetch(key, default)).tap { |value| raise ArgumentError, "#{key} must be positive" unless value.positive? } }
          rows = number.call("ROWS", 10_000)
          new(rows: rows, observations: number.call("OBSERVATIONS", rows), clusters: number.call("CLUSTERS", 50),
              probes: number.call("PROBES", 20), writes: number.call("WRITES", 500), k: number.call("K", 10),
              seed: number.call("SEED", 1), target: env["DB"], keep_db: env["KEEP_DB"] == "1")
        end
      end

      # Every embedding call answers the probe vector (VectorSearchStrategy's embedding_service).
      ProbeEmbedding = Struct.new(:vector) do
        # @return [Array<Float>]
        def embed(_text) = vector
      end

      TABLES = %w[memory_entities memory_observations].freeze
      SEARCH_LIMIT = 40 # HybridSearchStrategy runs each channel at limit * 2 (search's default 20)
      MERGE_THRESHOLD = 0.3 # suggest_merges' default
      STAMP = "'2026-01-02 00:00:00.000000'"

      # @param options [Options]
      # @param log [IO] progress lines
      def initialize(options, log: $stderr)
        @options = options
        @log = log
      end

      # @return [String] the Markdown report
      # @raise [Sandbox::Refused]
      def call
        started = clock
        Sandbox.new(target: @options.target, keep_db: @options.keep_db).run do |sandbox|
          progress("scratch database #{sandbox.target}: installing the VECTOR KEYs (EmbeddingIndexManager)")
          install_indexes!
          @server = server_settings
          seed!
          progress("writes with the VECTOR KEYs")
          @writes = { with: write_cost }
          progress("search latency, recall")
          @latency = latency
          @recall = recall
          @hazard = hazard
          progress("embeddings:drop_indexes, then writes without the VECTOR KEYs")
          @drop_ms = timed { EmbeddingIndexManager.drop_indexes! }
          @writes[:without] = write_cost
        end
        @elapsed = clock - started
        Report.new(self).to_markdown
      end

      # @return [Hash] what Report prints (after #call)
      def results
        { options: @options, server: @server, seed_ms: @seed_ms, latency: @latency, recall: @recall, hazard: @hazard,
          writes: @writes, drop_ms: @drop_ms, elapsed: @elapsed, merge_scan: @fixture.entity_ids.size }
      end

      private

      def connection = ActiveRecord::Base.connection

      def install_indexes!
        EmbeddingIndexManager.drop_indexes!
        result = EmbeddingIndexManager.add_indexes!
        raise Sandbox::Refused, "the VECTOR KEYs didn't converge: #{result[:message]}" unless result[:converged]
      end

      def seed!
        @fixture = Fixture.new(entities: @options.rows, observations: @options.observations, clusters: @options.clusters, seed: @options.seed)
        progress("seeding #{@options.rows} entities and #{@options.observations} observations")
        @seed_ms = timed { @fixture.insert!(connection) }
        @probes = Array.new(@options.probes) { |index| @fixture.probe(index) }
        ids = @fixture.entity_ids
        @anchors = MemoryEntity.where(id: Array.new(@options.probes) { |index| ids[index * ids.size / @options.probes] }).to_a
      end

      def server_settings
        variables = connection.select_rows("SHOW VARIABLES LIKE 'mhnsw%'").to_h
        { version: connection.select_value("SELECT VERSION()"), m: variables["mhnsw_default_m"],
          ef_search: variables["mhnsw_ef_search"], cache: variables["mhnsw_max_cache_size"].to_i }
      end

      # One timed run per probe (after one untimed warm-up), and whether its statements use the index.
      def latency
        channels.transform_values do |run|
          statements = capture { run.call(0) }
          { ms: Array.new(@options.probes) { |index| timed { run.call(index) } }, index: index_used?(statements) }
        end
      end

      def channels
        search = ->(index) { VectorSearchStrategy.new(embedding_service: ProbeEmbedding.new(@probes[index])) }
        {
          entity_exact: ->(index) { search.call(index).search("SynthQuery", limit: SEARCH_LIMIT) },
          entity_typed: ->(index) { search.call(index).search("SynthQuery", limit: SEARCH_LIMIT, entity_type: Fixture::TYPES[index % 10]) },
          entity_ann: ->(index) { connection.select_rows(ann_sql("memory_entities", @probes[index], SEARCH_LIMIT)) },
          entity_ann_binary: ->(index) { connection.select_rows(ann_sql("memory_entities", @probes[index], SEARCH_LIMIT, binary: true)) },
          observation_exact: ->(index) { search.call(index).search_observations("SynthQuery", limit: SEARCH_LIMIT) },
          observation_ann: ->(index) { connection.select_rows(ann_sql("memory_observations", @probes[index], SEARCH_LIMIT)) },
          merge_exact: ->(index) { suggest_merges_candidates(anchor(index)) },
          merge_ann: ->(index) { connection.select_rows(ann_sql("memory_entities", anchor(index).embedding.to_s.unpack("e*"), SEARCH_LIMIT)) },
          merge_evidence: ->(index) { EntityMergeEvidence.candidates_for(anchor(index)) }
        }
      end

      # An embedded entity, spread over the id range (the per-entity queries scan `id > ?`).
      def anchor(index) = @anchors[index % @anchors.size]

      # suggest_merges' per-entity query, as app/tools/suggest_merges_tool.rb runs it for each entity.
      def suggest_merges_candidates(entity)
        MemoryEntity.where.not(id: entity.id).with_embedding.where(entity_type: entity.entity_type).where("id > ?", entity.id)
                    .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, (SELECT embedding FROM memory_entities WHERE id = #{entity.id})) AS vec_distance")
                    .having("vec_distance < ?", MERGE_THRESHOLD).order(Arel.sql("vec_distance ASC")).limit(3).to_a
      end

      # The raw index shape, as step 2 plans it: the distance selected as `d`, the vector as the app
      # sends it (VEC_FromText of the text literal), or as a binary literal.
      def ann_sql(table, vector, limit, binary: false)
        literal = binary ? Fixture.binary_sql(vector) : "VEC_FromText(#{connection.quote(Fixture.text(vector))})"
        "SELECT id, VEC_DISTANCE_COSINE(embedding, #{literal}) AS d FROM #{table} ORDER BY d LIMIT #{limit}"
      end

      def recall
        TABLES.index_with do |table|
          @probes.map do |probe|
            ann = connection.select_values(Fixture.nearest_sql(table, probe, k: @options.k))
            exact = connection.select_values(Fixture.nearest_sql(table, probe, k: @options.k, exact: true))
            (ann & exact).size / @options.k.to_f
          end
        end
      end

      # The rows a one-type filter keeps: exact, the index with the WHERE (and how many of those are
      # in the exact top k), and the index's top k filtered afterwards.
      def hazard
        @probes.each_with_index.each_with_object(Hash.new(0)) do |(probe, index), rows|
          filter = "entity_type = #{connection.quote(Fixture::TYPES[index % 10])}"
          exact = connection.select_values(Fixture.nearest_sql("memory_entities", probe, k: @options.k, where: filter, exact: true))
          forced = connection.select_values(Fixture.nearest_sql("memory_entities", probe, k: @options.k, where: filter, force: true))
          rows[:exact] += exact.size
          rows[:index] += forced.size
          rows[:index_exact] += (forced & exact).size
          rows[:outside] += connection.select_values(Fixture.nearest_sql("memory_entities", probe, k: @options.k, outside: filter)).size
        end
      end

      # Single-row writes as the app makes them: an INSERT with no vector (the trigger stores the zero
      # vector; NULL without the index), then store_vector's compare-and-set UPDATE. Removed after.
      def write_cost
        owner = @fixture.entity_ids.first
        TABLES.to_h do |table|
          inserts = []
          embeds = []
          ids = Array.new(@options.writes) do |index|
            text = connection.quote(Fixture.text(@fixture.probe(index)))
            id = nil
            inserts << timed { id = connection.insert(insert_sql(table, index, owner)) }
            embeds << timed { connection.update("UPDATE #{table} SET embedding = VEC_FromText(#{text}), embedded_at = UTC_TIMESTAMP(6) WHERE id = #{id} AND updated_at = #{STAMP}") }
            id
          end
          (table == "memory_entities" ? MemoryEntity : MemoryObservation).where(id: ids).delete_all
          [ table, { insert: inserts, embed: embeds } ]
        end
      end

      def insert_sql(table, index, owner)
        if table == "memory_entities"
          "INSERT INTO memory_entities (name, entity_type, created_at, updated_at, embedding) VALUES ('SynthWrite#{index}', 'SynthType0', #{STAMP}, #{STAMP}, NULL)"
        else
          "INSERT INTO memory_observations (content, memory_entity_id, created_at, updated_at, embedding) VALUES ('SynthWrite#{index}', #{owner}, #{STAMP}, #{STAMP}, NULL)"
        end
      end

      def capture(&block)
        statements = []
        callback = ->(*, payload) { statements << payload[:sql].to_s if payload[:sql].to_s.match?(/VEC_DISTANCE/i) }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
        statements
      end

      def index_used?(statements) = Fixture.index_keys(connection, statements.uniq.first(3)).any?

      def timed
        started = clock
        yield
        (clock - started) * 1000
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def progress(line)
        @log.puts("[vector_bench] #{line}")
      end
    end
  end
end
