# frozen_string_literal: true

require "rails_helper"

RSpec.describe HybridSearchStrategy do
  let(:strategy) { described_class.new }

  let!(:entity_a) { MemoryEntity.create!(name: "AlphaTask", entity_type: "Task") }
  let!(:entity_b) { MemoryEntity.create!(name: "BetaTask", entity_type: "Task") }
  let!(:entity_c) { MemoryEntity.create!(name: "GammaTask", entity_type: "Task") }
  let!(:project_entity) { MemoryEntity.create!(name: "TestProject", entity_type: "Project") }

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

      it "boosts entities appearing in both text and vector results over vector-only" do
        results = strategy.search("query")
        entity_b_result = results.find { |r| r.entity.id == entity_b.id }
        entity_c_result = results.find { |r| r.entity.id == entity_c.id }
        expect(entity_b_result.score).to be > entity_c_result.score
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

      it "gives root project entity a stronger boost than child entities" do
        allow(GraphMemContext).to receive(:current_project_id).and_return(project_entity.id)
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(project_entity, score: 10.0),
          text_result(entity_a, score: 10.0)
        ])

        context_ids = [ project_entity.id, entity_a.id ]
        results = strategy.search("test", context_entity_ids: context_ids)
        project_score = results.find { |r| r.entity.id == project_entity.id }.score
        child_score = results.find { |r| r.entity.id == entity_a.id }.score

        expect(project_score).to be > child_score
      end
    end

    context "with entity type priority" do
      it "boosts Project entities over Task entities at equal text scores" do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 10.0),
          text_result(project_entity, score: 10.0)
        ])

        results = strategy.search("test")
        expect(results.first.entity.entity_type).to eq("Project")
      end

      it "applies configurable multipliers from SearchRelevanceBooster" do
        framework = MemoryEntity.create!(name: "FrameworkTest", entity_type: "Framework")
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 10.0),
          text_result(framework, score: 10.0)
        ])

        results = strategy.search("test")
        framework_result = results.find { |r| r.entity.id == framework.id }
        task_result = results.find { |r| r.entity.id == entity_a.id }
        expect(framework_result.score).to be > task_result.score
      ensure
        framework&.destroy
      end
    end

    context "with exact name match boost" do
      it "boosts entities whose name exactly matches the query" do
        exact_match = MemoryEntity.create!(name: "SearchTerm", entity_type: "Task")
        partial_match = MemoryEntity.create!(name: "SearchTerm Extended", entity_type: "Task")

        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(partial_match, score: 15.0),
          text_result(exact_match, score: 10.0)
        ])

        results = strategy.search("SearchTerm")
        expect(results.first.entity.id).to eq(exact_match.id)
      ensure
        exact_match&.destroy
        partial_match&.destroy
      end

      it "applies prefix match bonus when query is a prefix of entity name" do
        prefix_match = MemoryEntity.create!(name: "SearchTermExtended", entity_type: "Task")
        no_prefix = MemoryEntity.create!(name: "XSearchTerm", entity_type: "Task")

        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(no_prefix, score: 10.0),
          text_result(prefix_match, score: 10.0)
        ])

        results = strategy.search("SearchTerm")
        prefix_result = results.find { |r| r.entity.id == prefix_match.id }
        no_prefix_result = results.find { |r| r.entity.id == no_prefix.id }
        expect(prefix_result.score).to be > no_prefix_result.score
      ensure
        prefix_match&.destroy
        no_prefix&.destroy
      end
    end

    context "with structural importance boost" do
      it "boosts entities with more relations" do
        hub = MemoryEntity.create!(name: "HubEntity", entity_type: "Task")
        leaf = MemoryEntity.create!(name: "LeafEntity", entity_type: "Task")
        3.times do |i|
          target = MemoryEntity.create!(name: "Related#{i}", entity_type: "Task")
          MemoryRelation.create!(from_entity: hub, to_entity: target, relation_type: "relates_to")
        end

        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(leaf, score: 10.0),
          text_result(hub, score: 10.0)
        ])

        results = strategy.search("test")
        hub_result = results.find { |r| r.entity.id == hub.id }
        leaf_result = results.find { |r| r.entity.id == leaf.id }
        expect(hub_result.score).to be > leaf_result.score
      end
    end

    context "weighted RRF scoring" do
      it "preserves text score differentiation through fusion" do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 30.0),
          text_result(entity_b, score: 5.0)
        ])

        results = strategy.search("test")
        high = results.find { |r| r.entity.id == entity_a.id }
        low = results.find { |r| r.entity.id == entity_b.id }
        expect(high.score).to be > low.score
      end

      it "weights text contribution by normalized score" do
        allow_any_instance_of(EntitySearchStrategy).to receive(:search).and_return([
          text_result(entity_a, score: 20.0)
        ])
        allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([
          vector_result(entity_a, distance: 0.05)
        ])

        results = strategy.search("test")
        rrf_k = described_class::RRF_K
        text_rrf = (1.0 / (rrf_k + 0 + 1)) * (1.0 + 1.0) # normalized = 1.0 for single result
        vector_rrf = 1.0 / (rrf_k + 0 + 1)
        base_score = text_rrf + vector_rrf

        # Final score includes type priority and structural boost, but
        # should be proportional to the base RRF score
        expect(results.first.score).to be > base_score * 0.9
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
        name: "AlphaTask",
        entity_type: "Task",
        relevance_score: 0.1234,
        matched_fields: [ "name", "semantic" ]
      )
      expect(h).to have_key(:created_at)
      expect(h).to have_key(:updated_at)
    end
  end
end
