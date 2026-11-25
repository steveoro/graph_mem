# frozen_string_literal: true

require "rails_helper"

RSpec.describe ObservationRelevanceRanker do
  describe "#score" do
    it "returns higher scores for observations that match more query tokens" do
      ranker = described_class.new("graph_mem summarization")

      matching = instance_double(MemoryObservation, id: 1, content: "graph_mem summarization uses hybrid retrieval.", embedding: nil)
      partial = instance_double(MemoryObservation, id: 2, content: "graph_mem stores entities and relations.", embedding: nil)
      partial2 = instance_double(MemoryObservation, id: 2, content: "graph_mem is a Rails application.", embedding: nil)
      unrelated = instance_double(MemoryObservation, id: 3, content: "AnotherProject is a Rails application.", embedding: nil)

      # Related observations should score higher than partial observations
      expect(ranker.score(matching)).to be > ranker.score(partial)
      expect(ranker.score(matching)).to be > ranker.score(partial2)
      expect(ranker.score(partial)).to be >= ranker.score(partial2)

      # Partial observations should score higher than unrelated observations
      expect(ranker.score(partial)).to be > ranker.score(unrelated)
      expect(ranker.score(partial2)).to be > ranker.score(unrelated)
    end
  end

  describe "#score_batch" do
    it "returns one score per observation" do
      observations = [
        instance_double(MemoryObservation, id: 1, content: "graph_mem summarization", embedding: nil),
        instance_double(MemoryObservation, id: 2, content: "unrelated fact", embedding: nil)
      ]

      scores = described_class.new("graph_mem summarization").score_batch(observations)

      expect(scores.size).to eq(2)
      expect(scores.first).to be > scores.last
    end
  end

  # An unembedded row holds the zero vector, whose distance reads as 0.0 (spec/db/zero_vector_distance_spec.rb):
  # scored as a vector, it would get a similarity of 1.0, the maximum.
  describe "unembedded observations", :with_test_embeddings do
    include_context "zero-vector placeholders"

    let(:query) { "SynthEntity latency budget" }
    let(:entity) { MemoryEntity.create!(name: "SynthEntity1", entity_type: "Component") }

    before { record_embedding_calls! }

    it "gives an unembedded observation nil vector similarity, not 1.0" do
      embedded = MemoryObservation.create!(memory_entity: entity, content: query).reload
      pending_fact = unembedded { MemoryObservation.create!(memory_entity: entity, content: "SynthEntity has no vector yet") }

      similarities = described_class.new(query).send(:batch_vector_similarity, [ embedded, pending_fact ])

      expect(embedded.embedded_at).to be_present
      expect(similarities).to eq([ 1.0, nil ])
    end

    it "scores an unembedded observation on its tokens alone" do
      pending_fact = unembedded { MemoryObservation.create!(memory_entity: entity, content: "Unrelated housekeeping note") }

      expect(described_class.new(query).score_batch([ pending_fact ])).to eq([ 0.0 ])
    end

    it "reads the stamp from the row, so a stale in-memory copy isn't scored" do
      stale_copy = MemoryObservation.create!(memory_entity: entity, content: query).reload
      MemoryObservation.where(id: stale_copy.id).update_all(embedded_at: nil) # text changed elsewhere: re-embed pending

      expect(described_class.new(query).send(:batch_vector_similarity, [ stale_copy ])).to eq([ nil ])
    end
  end
end
