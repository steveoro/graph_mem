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

  # The order get_entities, traverse_graph and rank_observations return.
  describe "an unembedded observation", :with_test_embeddings do
    include_context "zero-vector placeholders"

    it "no longer ranks above an embedded one on the vector signal" do
      record_embedding_calls!
      service = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
      # Tokens: the embedded fact holds all four query tokens, the pending one two of them. The
      # embedded fact's test vector differs from the query's (similarity 0): 0.6 * 1.0 = 0.6. The
      # pending fact scored 0.6 * 0.5 + 0.4 * 1.0 = 0.7 on the placeholder's false 1.0; now 0.5.
      embedded = MemoryObservation.create!(memory_entity: service, content: "Alpha Service latency budget is 200 ms").reload
      pending_fact = unembedded { MemoryObservation.create!(memory_entity: service, content: "Alpha Service restarts nightly") }

      ranked = described_class.rank([ pending_fact, embedded ], query: "alpha service latency budget")

      expect(ranked).to eq([ embedded, pending_fact ])
    end
  end
end
