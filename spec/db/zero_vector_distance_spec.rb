# frozen_string_literal: true

require "rails_helper"

# Pins how MariaDB treats the zero vector, the placeholder an unembedded row holds on the index
# install (spec/support/zero_vector_helpers.rb). Its cosine distance to any vector is NaN: the client
# reads it as 0.0, a `<` comparison on it is false (`>=` is true), and arithmetic on it raises
# ERROR 1690. The `embedded_at` guards keep placeholders out of every distance query (step 0 of
# docs/plans/mariadb-vector-search-plan.md); if a MariaDB release changes any of this, these
# examples fail first. Gated on MariaDB 11.8+ (CI runs 11.8.6).
RSpec.describe "MariaDB cosine distance to the zero vector" do
  include_context "zero-vector placeholders"

  let(:connection) { ActiveRecord::Base.connection }
  let(:distance) { "VEC_DISTANCE_COSINE(VEC_FromText('[0,0,0,0]'), VEC_FromText('[1,0,0,0]'))" }

  before { skip "needs MariaDB #{ZeroVectorHelpers::MIN_MARIADB}+" unless ZeroVectorHelpers.mariadb_at_least? }

  it "reads as 0.0 in Ruby, although it is neither 0 nor NULL" do
    expect(connection.select_value("SELECT #{distance}")).to eq(0.0)
    expect(connection.select_value("SELECT #{distance} = 0")).to eq(0)
    expect(connection.select_value("SELECT #{distance} IS NULL")).to eq(0)
  end

  it "compares false against any distance threshold, so a HAVING drops the row" do
    expect(connection.select_value("SELECT #{distance} < 0.35")).to eq(0)
    expect(connection.select_value("SELECT #{distance} < 2")).to eq(0)
    expect(connection.select_rows("SELECT #{distance} AS d HAVING d < 2")).to be_empty
  end

  it "compares true with >=, so only a < threshold drops it" do
    expect(connection.select_value("SELECT #{distance} >= 0.35")).to eq(1)
  end

  it "raises ERROR 1690 on arithmetic" do
    [ "#{distance} + 0", "1.0 - #{distance}" ].each do |expression|
      expect { connection.select_value("SELECT #{expression}") }.to raise_error(ActiveRecord::StatementInvalid) { |error|
        expect(error.cause.error_number).to eq(1690)
      }
    end
  end

  it "holds for the placeholder an unembedded row stores" do
    entity = unembedded { MemoryEntity.create!(name: "SynthEntity1", entity_type: "Component") }
    unit = connection.quote("[1#{',0' * (EmbeddingHelper::DEFAULT_TEST_DIMS - 1)}]")
    distance_sql = "VEC_DISTANCE_COSINE(embedding, VEC_FromText(#{unit}))"

    expect(MemoryEntity.where(id: entity.id).pick(Arel.sql(distance_sql))).to eq(0.0)
    expect(connection.select_rows("SELECT id, #{distance_sql} AS d FROM memory_entities WHERE id = #{entity.id} HAVING d < 2")).to be_empty
  end
end
