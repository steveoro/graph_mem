# frozen_string_literal: true

require "rails_helper"

# ANN against exact on the clustered fixture (spec/support/vector_index_fixture.rb), step 1 of
# docs/plans/mariadb-vector-search-plan.md, with the server's index settings (default M=6,
# mhnsw_ef_search=20). One probe per cluster and table: a fresh vector near the cluster's center.
# ANN is the raw index shape (`ORDER BY VEC_DISTANCE_COSINE(...) LIMIT 10`), exact the top 10 of the
# embedded rows. The index's graph is built in insert order with its own randomness, so recall
# varies from run to run on the same rows: the measured floor sits well under the lowest run.
RSpec.describe "Vector index recall against exact search", :with_test_embeddings do
  include_context "vector index fixture"

  before(:all) do
    @recall = VectorIndexFixture::TABLES.index_with do |table|
      Array.new(@fixture.clusters) do |cluster|
        probe = @fixture.probe(cluster)
        ann = VectorIndexFixture.nearest_ids(table, probe)
        exact = VectorIndexFixture.nearest_ids(table, probe, exact: true)
        { ann: ann.size, exact: exact.size, recall: (ann & exact).size / VectorIndexFixture::K.to_f }
      end
    end
  end

  let(:per_probe) { @recall.transform_values { |probes| probes.pluck(:recall) } }
  let(:average) { per_probe.values.flatten.sum / per_probe.values.flatten.size }

  it "answers 10 rows per probe through the index, at a recall@10 above the measured floor" do
    VectorIndexFixture::TABLES.each do |table|
      expect(index_keys([ nearest_sql(table, @fixture.probe(0)) ])).to eq([ "idx_#{table}_embedding" ])
    end
    expect(@recall.values.flatten.pluck(:ann, :exact)).to all(eq([ 10, 10 ]))
    expect(average).to be >= VectorIndexFixture::MEASURED_RECALL_FLOOR, "recall@10 #{average.round(3)} per probe: #{per_probe}"
  end

  # Decision 4 of the plan: >= 0.8 average recall@10, no probe below 0.5.
  it "clears the Decision 4 bar: average recall@10 >= 0.8, no probe below 0.5" do
    pending "step 2 (PR C) tunes K, mhnsw_ef_search or the index M until the ANN path clears this bar"
    expect([ average, per_probe.values.flatten.min ]).to satisfy("average >= 0.8 and min >= 0.5, got #{average.round(3)} / #{per_probe}") { |avg, min|
      avg >= 0.8 && min >= 0.5
    }
  end

  # The index returns its nearest rows before the WHERE applies, and the LIMIT caps them. This is why
  # searches with a filter (a type, a project scope, a perspective) stay exact scans. With the WHERE
  # inside, MariaDB keeps walking the graph and returns 136-198 of the 200 rows (30 local runs), but
  # only 38-135 of the exact ones; the index's top 10 filtered afterwards (step 2's inner query) keeps
  # 20-34.
  it "returns fewer of the exact rows with a one-type filter, so filtered searches stay exact" do
    rows = Array.new(@fixture.clusters) do |cluster|
      probe = @fixture.probe(cluster)
      filter = "entity_type = #{ActiveRecord::Base.connection.quote(GraphMem::VectorBench::Fixture::TYPES[cluster % 10])}"
      exact = nearest_ids("memory_entities", probe, where: filter, exact: true)
      {
        exact: exact.size,
        index_with_where: (nearest_ids("memory_entities", probe, where: filter, force: true) & exact).size,
        where_outside: nearest_ids("memory_entities", probe, outside: filter).size
      }
    end

    forced = nearest_sql("memory_entities", @fixture.probe(0), where: "entity_type = 'SynthType0'", force: true)
    expect(index_keys([ forced ])).to eq([ "idx_memory_entities_embedding" ])
    expect(rows.pluck(:exact)).to all(eq(10))
    expect(rows.sum { |row| row[:index_with_where] }).to be < rows.sum { |row| row[:exact] } * 0.9
    expect(rows.sum { |row| row[:where_outside] }).to be < rows.sum { |row| row[:exact] } / 2
  end
end
