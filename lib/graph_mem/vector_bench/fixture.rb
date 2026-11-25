# frozen_string_literal: true

module GraphMem
  module VectorBench
    # Synthetic rows for the vector-index bench (`graph_mem:vector_bench`) and the vector-index specs
    # (spec/db/vector_index_*_spec.rb), step 1 of docs/plans/mariadb-vector-search-plan.md: 768-d
    # unit vectors in clusters, 5% zero-vector placeholders (`embedded_at` NULL, as an unembedded row
    # holds on the index install), generic names (`SynthEntity123`, `SynthFact123`) and 10 synthetic
    # types drawn independently of the cluster, so a one-type filter keeps about a tenth of any
    # neighbourhood. Each observation belongs to an entity of its own cluster. The same seed gives
    # the same rows.
    #
    # Rows go in through raw multi-row INSERTs (no model callbacks, no embedding calls), vectors as
    # packed float32 hex literals, one batch at a time: only the clusters and ids stay in memory.
    #
    #   fixture = Fixture.new(entities: 1_000, observations: 1_000, clusters: 20, seed: 7)
    #   fixture.insert!(ActiveRecord::Base.connection) # => { entities: 1000, observations: 1000 }
    #   fixture.probe(3)                               # => a unit query vector near cluster 3
    #   fixture.entity_ids                             # => the embedded entities' ids
    class Fixture
      DIMS = 768
      TYPES = Array.new(10) { |index| "SynthType#{index}" }.freeze
      PLACEHOLDER_SHARE = 0.05
      # Target cosine distances between two members of one cluster and of two clusters. Text
      # embeddings share a common direction (unrelated texts are not orthogonal), so a vector is a
      # shared unit direction plus a unit cluster center plus uniform noise, weighted to land on
      # these. Tie-heavy: a probe's top 10 sit within a few hundredths of each other.
      MEMBER_DISTANCE = 0.3
      CLUSTER_DISTANCE = 0.6
      BATCH = 250
      STAMP = "'2026-01-01 00:00:00.000000'"

      # @return [Integer] the number of clusters
      attr_reader :clusters

      # @param entities [Integer] entity rows
      # @param observations [Integer] observation rows
      # @param clusters [Integer] cluster count
      # @param seed [Integer] the random seed
      def initialize(entities:, observations: entities, clusters: 20, seed: 1)
        @entity_count = Integer(entities)
        @observation_count = Integer(observations)
        @clusters = Integer(clusters)
        @random = Random.new(Integer(seed))
        @shared = unit(Array.new(DIMS) { uniform })
        @centers = Array.new(@clusters) { unit(Array.new(DIMS) { uniform }) }
        # |v|² = shared² + 1 + noise² = total; one cluster: 1 - (shared² + 1) / total = MEMBER_DISTANCE;
        # two clusters: 1 - shared² / total = CLUSTER_DISTANCE. Uniform(-1, 1) noise has norm √(DIMS/3).
        total = 1.0 / (CLUSTER_DISTANCE - MEMBER_DISTANCE)
        @shared_weight = Math.sqrt((1 - CLUSTER_DISTANCE) * total)
        @noise_scale = Math.sqrt(total - 1 - (@shared_weight**2)) / Math.sqrt(DIMS / 3.0)
      end

      # Inserts the entities, then the observations, through +connection+.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @param batch [Integer] rows per INSERT statement
      # @return [Hash{Symbol => Integer}] the rows inserted per table
      def insert!(connection, batch: BATCH)
        @entity_clusters = Array.new(@entity_count) { @random.rand(@clusters) }
        @placeholders = Array.new(@entity_count) { placeholder? }
        @entity_count.times.each_slice(batch) { |indexes| connection.execute(entity_sql(connection, indexes)) }
        names = connection.select_rows("SELECT id, name FROM memory_entities WHERE name LIKE 'SynthEntity%'")
        by_index = names.to_h { |id, name| [ name.delete_prefix("SynthEntity").to_i, id.to_i ] }
        @entity_ids = Array.new(@entity_count) { |index| by_index.fetch(index) }
        owners = @entity_ids.each_with_index.group_by { |_, index| @entity_clusters[index] }.transform_values { |pairs| pairs.map(&:first) }
        @observation_count.times.each_slice(batch) { |indexes| connection.execute(observation_sql(indexes, owners)) }
        { entities: @entity_count, observations: @observation_count }
      end

      # A query vector near cluster +cluster+, never stored.
      #
      # @param cluster [Integer]
      # @return [Array<Float>] a unit vector of DIMS floats
      def probe(cluster)
        member(cluster % @clusters)
      end

      # @return [Array<Integer>] the embedded entities' ids, in insert order (after #insert!)
      def entity_ids
        @entity_ids.reject.with_index { |_, index| @placeholders[index] }
      end

      # @param vector [Array<Float>]
      # @return [String] the body of a VEC_FromText literal, "[f1,f2,...]"
      def self.text(vector)
        "[#{vector.join(',')}]"
      end

      # @param vector [Array<Float>, nil] nil: the zero vector
      # @return [String] an SQL hex literal of the packed float32 vector
      def self.binary_sql(vector)
        "x'#{(vector || Array.new(DIMS, 0.0)).pack('e*').unpack1('H*')}'"
      end

      # The SELECT of the +k+ nearest ids. The vector goes in as a binary literal: a
      # `VEC_FromText('…')` outside a HAVING is parsed again for every row an exact scan reads (about
      # 40 µs a row for a full-precision 768-d vector on MariaDB 11.8.9).
      #
      # @param table [String] memory_entities or memory_observations
      # @param vector [Array<Float>] the query vector
      # @param k [Integer] the LIMIT
      # @param where [String, nil] an SQL condition
      # @param exact [Boolean] true: the exact top k of the embedded rows (`(d + 0)` keeps the index
      #   out); false: the raw index shape, `ORDER BY VEC_DISTANCE_COSINE(...) LIMIT k`
      # @param force [Boolean] FORCE INDEX (with a WHERE the optimizer may pick a B-tree instead)
      # @param outside [String, nil] an SQL condition applied after the LIMIT, to the k rows found
      #   (step 2's inner-query shape)
      # @return [String]
      def self.nearest_sql(table, vector, k:, where: nil, exact: false, force: false, outside: nil)
        distance = "VEC_DISTANCE_COSINE(embedding, #{binary_sql(vector)})"
        conditions = [ where, ("embedded_at IS NOT NULL" if exact) ].compact
        hint = " FORCE INDEX (idx_#{table}_embedding)" if force
        sql = "SELECT #{outside ? '*' : 'id'} FROM #{table}#{hint}#{" WHERE #{conditions.join(' AND ')}" if conditions.any?} " \
              "ORDER BY #{exact ? "(#{distance} + 0)" : distance} LIMIT #{Integer(k)}"
        outside ? "SELECT id FROM (#{sql}) nearest WHERE #{outside}" : sql
      end

      # The vector indexes the EXPLAIN of each statement names as `key`.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @param statements [Array<String>] SELECT statements (the app's own, or #nearest_sql's)
      # @return [Array<String>] idx_memory_entities_embedding and/or idx_memory_observations_embedding
      def self.index_keys(connection, statements)
        statements.flat_map { |sql| connection.select_all("EXPLAIN #{sql}").pluck("key") }.compact & EmbeddingIndexStatus::INDEX_NAMES.values
      end

      private

      def uniform = (@random.rand * 2) - 1

      def placeholder? = @random.rand < PLACEHOLDER_SHARE

      def member(cluster)
        center = @centers.fetch(cluster)
        unit(Array.new(DIMS) { |dim| (@shared_weight * @shared[dim]) + center[dim] + (@noise_scale * uniform) })
      end

      def unit(vector)
        norm = Math.sqrt(vector.sum { |value| value * value })
        vector.map { |value| value / norm }
      end

      def entity_sql(connection, indexes)
        values = indexes.map do |index|
          vector = (member(@entity_clusters[index]) unless @placeholders[index])
          type = connection.quote(TYPES[@random.rand(TYPES.size)])
          "('SynthEntity#{index}', #{type}, #{STAMP}, #{STAMP}, #{self.class.binary_sql(vector)}, #{vector ? STAMP : 'NULL'}, 0)"
        end
        "INSERT INTO memory_entities (name, entity_type, created_at, updated_at, embedding, embedded_at, " \
          "memory_observations_count) VALUES #{values.join(', ')}"
      end

      def observation_sql(indexes, owners)
        values = indexes.map do |index|
          cluster = @random.rand(@clusters)
          candidates = owners[cluster] || @entity_ids
          vector = (member(cluster) unless placeholder?)
          "('SynthFact#{index}', #{candidates[@random.rand(candidates.size)]}, #{STAMP}, #{STAMP}, " \
            "#{self.class.binary_sql(vector)}, #{vector ? STAMP : 'NULL'})"
        end
        "INSERT INTO memory_observations (content, memory_entity_id, created_at, updated_at, embedding, embedded_at) " \
          "VALUES #{values.join(', ')}"
      end
    end
  end
end
