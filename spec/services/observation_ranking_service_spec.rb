# frozen_string_literal: true

require "rails_helper"

RSpec.describe ObservationRankingService do
  let!(:entity) { MemoryEntity.create!(name: "RankEntity", entity_type: "Task") }
  let!(:relevant) { MemoryObservation.create!(memory_entity: entity, content: "graph mem summarization") }
  let!(:generic) { MemoryObservation.create!(memory_entity: entity, content: "unrelated housekeeping") }

  before do
    relevant.update_column(:trust_score, 0.2)
    generic.update_column(:trust_score, 0.9)
    relevant.reload
    generic.reload
  end

  it "ranks by trust when no query is provided" do
    ranked = described_class.rank([ relevant, generic ], mode: "trust")
    expect(ranked.first).to eq(generic)
  end

  it "ranks by query relevance when query is provided" do
    ranked = described_class.rank([ relevant, generic ], query: "graph mem summarization")
    expect(ranked.first).to eq(relevant)
  end
end
