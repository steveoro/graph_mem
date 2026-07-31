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
end
