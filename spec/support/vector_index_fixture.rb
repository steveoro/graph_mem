# frozen_string_literal: true

# The clustered fixture of the vector-index specs (step 1 of docs/plans/mariadb-vector-search-plan.md):
# GraphMem::VectorBench::Fixture's rows, the generator of the `graph_mem:vector_bench` task, at
# 1,000 entities and 1,000 observations (5% zero-vector placeholders), on the index install the
# committed schema has (spec/support/zero_vector_helpers.rb).
#
# The rows are seeded once per group, inside a group-level transaction: `before(:all)` pins the
# connection the way the fixture transactions do (ActiveRecord's pin_connection!, which opens a real
# transaction), so each example's fixture transaction nests as a savepoint, and `after(:all)` rolls
# the group transaction back. MariaDB's vector index is InnoDB, so it rolls back too: nothing is
# committed, a killed run leaves nothing behind, and `after(:all)` checks the tables are empty again.
# The group is skipped below MariaDB 11.8.
#
#   RSpec.describe "Vector search shapes", :with_test_embeddings do
#     include_context "vector index fixture"
#
#     it "doesn't use the index" do
#       expect(index_keys([ "SELECT …" ])).to be_empty
#     end
#   end
module VectorIndexFixture
  ENTITIES = 1_000
  OBSERVATIONS = 1_000
  CLUSTERS = 20
  SEED = 20_261_125
  K = 10
  # The recall spec's floor. Recall@10 averaged over its 40 probes measured 0.37-0.85 in 30 local runs
  # on this fixture (MariaDB 11.8.9; one table alone fell to 0.09 once), with probes at 0 in almost
  # every run (the search stays in a wrong cluster) and none clearing Decision 4's bar, which stays
  # pending until step 2 tunes the ANN path.
  MEASURED_RECALL_FLOOR = 0.2
  TABLES = EmbeddingIndexStatus::INDEX_NAMES.keys.map(&:to_s).freeze

  module_function

  # @return [Hash{String => Integer}] the rows per memory table
  def row_counts
    connection = ActiveRecord::Base.connection
    TABLES.index_with { |table| connection.select_value("SELECT COUNT(*) FROM #{table}").to_i }
  end

  # @param statements [Array<String>] SELECT statements
  # @return [Array<String>] the vector indexes their EXPLAIN rows name as `key`
  def index_keys(statements)
    GraphMem::VectorBench::Fixture.index_keys(ActiveRecord::Base.connection, statements)
  end

  # @param (see GraphMem::VectorBench::Fixture.nearest_sql)
  # @return [String] the SELECT of the K nearest ids
  def nearest_sql(table, vector, k: K, **options)
    GraphMem::VectorBench::Fixture.nearest_sql(table, vector, k: k, **options)
  end

  # @return [Array<Integer>] the ids #nearest_sql selects
  def nearest_ids(...)
    ActiveRecord::Base.connection.select_values(nearest_sql(...)).map(&:to_i)
  end
end

RSpec.shared_context "vector index fixture" do
  include_context "zero-vector placeholders"
  include VectorIndexFixture

  before(:all) do
    skip "needs MariaDB #{ZeroVectorHelpers::MIN_MARIADB}+" unless ZeroVectorHelpers.mariadb_at_least?
    counts = VectorIndexFixture.row_counts
    raise "The vector index fixture needs empty memory tables, found #{counts}" unless counts.values.all?(&:zero?)

    ActiveRecord::Base.connection_pool.pin_connection!(true)
    @vector_fixture_pinned = true
    @fixture = GraphMem::VectorBench::Fixture.new(
      entities: VectorIndexFixture::ENTITIES, observations: VectorIndexFixture::OBSERVATIONS,
      clusters: VectorIndexFixture::CLUSTERS, seed: VectorIndexFixture::SEED
    )
    @fixture.insert!(ActiveRecord::Base.connection)
  end

  after(:all) do
    next unless @vector_fixture_pinned

    clean = ActiveRecord::Base.connection_pool.unpin_connection!
    counts = VectorIndexFixture.row_counts
    raise "The vector index fixture's transaction was committed (#{counts})" unless clean && counts.values.all?(&:zero?)
  end
end
