# frozen_string_literal: true

require "rails_helper"

RSpec.describe HybridSearchStrategy do
  let(:strategy) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: "AlphaProject", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "BetaTask", entity_type: "Task") }
  let!(:entity_c) { MemoryEntity.create!(name: "GammaComponent", entity_type: "Component") }

  def text_result(entity, score: 10.0, matched_fields: [ "name" ])
    EntitySearchStrategy::SearchResult.new(entity, score, matched_fields)
  end

  def vector_result(entity, distance: 0.1)
    VectorSearchStrategy::SearchResult.new(entity: entity, distance: distance)
  end

  before do
    allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([])
  end

  describe "#search" do
    context "text-only fallback (no vector results)" do
      before do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 20.0),
          text_result(entity_b, score: 10.0)
        ])
      end

      it "returns text results when vector results are empty" do
        results = strategy.search("alpha", semantic: true)
        expect(results.length).to eq(2)
        expect(results.first.entity).to eq(entity_a)
      end

      it "returns text results when semantic is false" do
        results = strategy.search("alpha", semantic: false)
        expect(results.length).to eq(2)
      end
    end

    context "with both text and vector results (RRF fusion)" do
      before do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 20.0),
          text_result(entity_b, score: 10.0)
        ])
        allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([
          vector_result(entity_b, distance: 0.05),
          vector_result(entity_c, distance: 0.1)
        ])
      end

      it "fuses results using RRF" do
        results = strategy.search("query")
        ids = results.map { |r| r.entity.id }
        expect(ids).to include(entity_a.id, entity_b.id, entity_c.id)
      end

      it "boosts entities appearing in both text and vector results" do
        results = strategy.search("query")
        entity_b_result = results.find { |r| r.entity.id == entity_b.id }
        entity_a_result = results.find { |r| r.entity.id == entity_a.id }
        expect(entity_b_result.score).to be > entity_a_result.score
      end

      it "includes 'semantic' in matched_fields for vector-matched entities" do
        results = strategy.search("query")
        entity_c_result = results.find { |r| r.entity.id == entity_c.id }
        expect(entity_c_result.matched_fields).to include("semantic")
      end

      it "respects the limit parameter" do
        results = strategy.search("query", limit: 2)
        expect(results.length).to eq(2)
      end
    end

    context "with context boosting" do
      before do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 10.0),
          text_result(entity_b, score: 10.0)
        ])
      end

      it "boosts in-context entities in text-only mode" do
        results = strategy.search("test", context_entity_ids: [ entity_b.id ])
        scores = results.map { |r| [ r.entity.id, r.score ] }.to_h
        expect(scores[entity_b.id]).to be > scores[entity_a.id]
      end

      it "boosts in-context entities in fused mode" do
        allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([
          vector_result(entity_a, distance: 0.1),
          vector_result(entity_b, distance: 0.1)
        ])

        results = strategy.search("test", context_entity_ids: [ entity_b.id ])
        scores = results.map { |r| [ r.entity.id, r.score ] }.to_h
        expect(scores[entity_b.id]).to be > scores[entity_a.id]
      end

      it "does not boost when context_entity_ids is nil" do
        results = strategy.search("test", context_entity_ids: nil)
        scores = results.map(&:score).uniq
        expect(scores.length).to eq(1)
      end
    end
  end

  describe "SearchResult#to_h" do
    it "returns a hash with all expected keys" do
      result = described_class::SearchResult.new(
        entity: entity_a,
        score: 0.1234,
        matched_fields: [ "name", "semantic" ]
      )
      h = result.to_h
      expect(h).to include(
        entity_id: entity_a.id,
        name: "AlphaProject",
        entity_type: "Project",
        relevance_score: 0.1234,
        matched_fields: [ "name", "semantic" ]
      )
      expect(h).to have_key(:created_at)
      expect(h).to have_key(:updated_at)
    end
  end

  describe "RRF scoring math" do
    it "calculates correct RRF scores" do
      rrf_k = described_class::RRF_K
      rank_0_score = 1.0 / (rrf_k + 0 + 1)
      rank_1_score = 1.0 / (rrf_k + 1 + 1)

      allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
        text_result(entity_a, score: 20.0)
      ])
      allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([
        vector_result(entity_a, distance: 0.05)
      ])

      results = strategy.search("test")
      combined_score = rank_0_score * 2
      expect(results.first.score).to be_within(0.0001).of(combined_score)
    end
  end
end
