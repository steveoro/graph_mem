# frozen_string_literal: true

require "rails_helper"

RSpec.describe SummarizerService do
  let!(:entity) do
    MemoryEntity.create!(name: "Steve", entity_type: "User", description: "Developer")
  end

  let!(:active_observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "Steve prefers Ruby for Rails projects.",
      confidence: 0.9,
      source: "profile"
    )
  end

  let!(:obsolete_observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "Steve prefers Perl.",
      confidence: 0.5
    ).tap(&:mark_obsolete!)
  end

  before do
    AppSettings.clear_cache
    AppSettings.enable_llm_summarization = false
  end

  after { AppSettings.clear_cache }

  describe ".call" do
    it "requires a query" do
      expect { described_class.call(query: "") }.to raise_error(ArgumentError, "query is required")
    end

    it "returns deterministic evidence for active observations only" do
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )

      result = described_class.call(query: "Steve programming languages")

      expect(result[:generation_mode]).to eq("deterministic")
      expect(result[:generated_by]).to eq("deterministic")
      expect(result[:observation_count]).to eq(1)
      expect(result[:observations].map { |obs| obs[:content] }).to contain_exactly(active_observation.content)
      expect(result[:sources]).to eq([ { entity_id: entity.id, observation_id: active_observation.id } ])
    end

    it "falls back when LLM summarization is disabled" do
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )
      expect(SummaryGenerationClient).not_to receive(:generate)

      result = described_class.call(query: "Steve")

      expect(result[:fallback_reason]).to eq("disabled")
      expect(result[:summary]).to include("Steve")
    end

    it "uses LLM synthesis when enabled and configured" do
      AppSettings.enable_llm_summarization = true
      AppSettings.summary_url = "http://summary.test:11434"
      AppSettings.summary_model = "qwen3:8b"
      AppSettings.summary_provider = "ollama"

      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )
      allow(SummaryGenerationClient).to receive(:generate).and_return(
        { ok: true, text: "Steve primarily uses Ruby.", error: nil }
      )

      result = described_class.call(query: "Steve")

      expect(result[:generation_mode]).to eq("llm")
      expect(result[:generated_by]).to eq("qwen3:8b")
      expect(result[:summary]).to eq("Steve primarily uses Ruby.")
      expect(result[:sources]).not_to be_empty
    end

    it "falls back when the provider fails" do
      AppSettings.enable_llm_summarization = true
      AppSettings.summary_url = "http://summary.test:11434"
      AppSettings.summary_model = "qwen3:8b"
      AppSettings.summary_provider = "ollama"

      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )
      allow(SummaryGenerationClient).to receive(:generate).and_return(
        { ok: false, text: nil, error: "provider_unavailable" }
      )

      result = described_class.call(query: "Steve")

      expect(result[:generation_mode]).to eq("deterministic")
      expect(result[:fallback_reason]).to eq("provider_unavailable")
      expect(result[:observations]).not_to be_empty
    end

    it "scopes to a single entity when entity_id is provided" do
      other = MemoryEntity.create!(name: "Other", entity_type: "User")
      MemoryObservation.create!(memory_entity: other, content: "Unrelated fact.")

      result = described_class.call(query: "Steve", entity_id: entity.id)

      expect(result[:entity_count]).to eq(1)
      expect(result[:observations].map { |obs| obs[:memory_entity_id] }).to all(eq(entity.id))
    end

    it "caps evidence per entity when observations_per_entity is set" do
      other = MemoryEntity.create!(name: "Other", entity_type: "Project")
      3.times { |i| MemoryObservation.create!(memory_entity: other, content: "Other fact #{i}.") }
      3.times { |i| MemoryObservation.create!(memory_entity: entity, content: "Entity fact #{i}.") }

      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.95, matched_fields: [ "name" ]),
          HybridSearchStrategy::SearchResult.new(entity: other, score: 0.85, matched_fields: [ "name" ])
        ])
      )

      result = described_class.call(query: "facts", max_observations: 10, observations_per_entity: 2)

      counts = result[:sources].group_by { |s| s[:entity_id] }.transform_values(&:count)
      expect(counts.values).to all(be <= 2)
      expect(result[:observation_count]).to eq(4)
      expect(counts.keys).to contain_exactly(entity.id, other.id)
    end

    it "disables the per-entity cap when observations_per_entity is 0" do
      other = MemoryEntity.create!(name: "Other", entity_type: "Project")
      4.times { |i| MemoryObservation.create!(memory_entity: other, content: "Other fact #{i}.") }
      4.times { |i| MemoryObservation.create!(memory_entity: entity, content: "Entity fact #{i}.") }

      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.95, matched_fields: [ "name" ]),
          HybridSearchStrategy::SearchResult.new(entity: other, score: 0.85, matched_fields: [ "name" ])
        ])
      )

      result = described_class.call(query: "facts", max_observations: 4, observations_per_entity: 0)

      counts = result[:sources].group_by { |s| s[:entity_id] }.transform_values(&:count)
      expect(counts[entity.id]).to eq(4)
    end
  end
end
