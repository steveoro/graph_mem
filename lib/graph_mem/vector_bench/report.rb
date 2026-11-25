# frozen_string_literal: true

module GraphMem
  module VectorBench
    # The Markdown of a `graph_mem:vector_bench` run (Runner#results), for a PR body.
    #
    #   Report.new(runner).to_markdown # => "## Vector bench: 10,000 entities, …"
    class Report
      CHANNELS = {
        entity_exact: [ "Entity search", "`VectorSearchStrategy#search`, limit %<limit>d (exact)" ],
        entity_typed: [ "Entity search, one type", "`#search(entity_type:)`, limit %<limit>d (exact)" ],
        entity_ann: [ "Entity search", "raw index shape, `ORDER BY d LIMIT %<limit>d`" ],
        entity_ann_binary: [ "Entity search", "the same, the vector as a binary literal" ],
        observation_exact: [ "Observation search", "`#search_observations`, limit %<limit>d (exact)" ],
        observation_ann: [ "Observation search", "raw index shape, `ORDER BY d LIMIT %<limit>d`" ],
        merge_exact: [ "`suggest_merges`, one entity", "the tool's per-entity query (exact)" ],
        merge_ann: [ "`suggest_merges`, one entity", "raw index shape, `ORDER BY d LIMIT %<limit>d`" ],
        merge_evidence: [ "Merge evidence, one entity", "`EntityMergeEvidence.candidates_for` (exact)" ]
      }.freeze

      # @param runner [Runner] a runner after #call
      def initialize(runner)
        @results = runner.results
        @options = @results[:options]
      end

      # @return [String]
      def to_markdown
        [ header, latency, recall, writes ].join("\n\n") << "\n"
      end

      private

      def header
        server = @results[:server]
        seeded = @options.rows + @options.observations
        <<~MD.chomp
          ## Vector bench: #{number(@options.rows)} entities, #{number(@options.observations)} observations

          MariaDB #{server[:version]}; index settings `mhnsw_default_m` #{server[:m]}, `mhnsw_ef_search` #{server[:ef_search]}, `mhnsw_max_cache_size` #{server[:cache] / 1.megabyte} MiB. Synthetic rows (`GraphMem::VectorBench::Fixture`): #{@options.clusters} clusters, 5% zero-vector placeholders, 10 types, seed #{@options.seed}; #{@options.probes} probes per channel; the run took #{duration(@results[:elapsed])}. Seeding with the VECTOR KEYs (multi-row INSERTs of #{Fixture::BATCH}): #{number(seeded)} rows in #{duration(@results[:seed_ms] / 1000)}, #{number(seeded / (@results[:seed_ms] / 1000))} rows/s.
        MD
      end

      def latency
        rows = CHANNELS.map do |key, (channel, query)|
          sample = @results[:latency].fetch(key)
          "| #{channel} | #{format(query, limit: Runner::SEARCH_LIMIT)} | #{sample[:index] ? 'yes' : 'no'} | #{ms(percentile(sample[:ms], 0.5))} | #{ms(percentile(sample[:ms], 0.95))} |"
        end
        per_entity = percentile(@results[:latency][:merge_exact][:ms], 0.5)
        <<~MD.chomp
          ### Search latency

          | Channel | Query | Index | p50 ms | p95 ms |
          |---|---|---|---:|---:|
          #{rows.join("\n")}

          One `suggest_merges` call that finds fewer than `limit` pairs runs the per-entity query for each of the #{number(@results[:merge_scan])} embedded entities: about #{duration(@results[:merge_scan] * per_entity / 1000)} at the p50.
        MD
      end

      def recall
        rows = @results[:recall].map do |table, values|
          "| #{table} | #{(values.sum / values.size).round(3)} | #{values.min.round(2)} | #{values.count { |value| value < 0.5 }} of #{values.size} |"
        end
        hazard = @results[:hazard]
        <<~MD.chomp
          ### Recall@#{@options.k} of the raw index shape against exact

          | Table | Average | Lowest probe | Probes below 0.5 |
          |---|---:|---:|---:|
          #{rows.join("\n")}

          Decision 4's bar: average >= 0.8 and no probe below 0.5. With a one-type filter (one of 10 types, top #{@options.k}, #{@options.probes} probes) exact returns #{hazard[:exact]} rows, the index with the WHERE (FORCE INDEX) #{hazard[:index]} (#{hazard[:index_exact]} of them in the exact top #{@options.k}), and the index's top #{@options.k} filtered afterwards #{hazard[:outside]}.
        MD
      end

      def writes
        rows = Runner::TABLES.flat_map do |table|
          { insert: "INSERT (no vector)", embed: "embedding UPDATE (`store_vector`)" }.flat_map do |kind, label|
            { with: "yes", without: "no" }.map do |state, keys|
              sample = @results[:writes].fetch(state).fetch(table).fetch(kind)
              "| #{table} | #{label} | #{keys} | #{number(sample.size / (sample.sum / 1000))} | #{ms(percentile(sample, 0.5))} | #{ms(percentile(sample, 0.95))} |"
            end
          end
        end
        <<~MD.chomp
          ### Write cost (#{number(@options.writes)} single-row writes per table)

          | Table | Write | VECTOR KEYs | rows/s | p50 ms | p95 ms |
          |---|---|---|---:|---:|---:|
          #{rows.join("\n")}

          `EmbeddingIndexManager.drop_indexes!` (`embeddings:drop_indexes`) on the seeded tables took #{duration(@results[:drop_ms] / 1000)}.
        MD
      end

      # Nearest-rank percentile.
      def percentile(values, share)
        sorted = values.sort
        sorted[[ (share * sorted.size).ceil - 1, 0 ].max]
      end

      def ms(value) = format("%.2f", value)

      def number(value) = ActiveSupport::NumberHelper.number_to_delimited(value.round)

      def duration(seconds)
        seconds < 60 ? format("%.1f s", seconds) : format("%d min %d s", seconds / 60, seconds % 60)
      end
    end
  end
end
