# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Summarize integration", type: :integration do
  let!(:entity) do
    MemoryEntity.create!(name: "GraphMem", entity_type: "Project")
  end

  let!(:active_observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "GraphMem supports hybrid search and trust scores."
    )
  end

  let!(:obsolete_observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "GraphMem only supports text search."
    ).tap { |obs| obs.mark_obsolete!(reason: "superseded") }
  end

  before do
    AppSettings.clear_cache
    AppSettings.enable_llm_summarization = false
  end

  after { AppSettings.clear_cache }

  it "returns deterministic sourced evidence without an external LLM" do
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [
        HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.95, matched_fields: [ "name" ])
      ])
    )

    result = SummarizerService.call(query: "GraphMem search")

    expect(result[:generation_mode]).to eq("deterministic")
    expect(result[:observations].map { |obs| obs[:id] }).to contain_exactly(active_observation.id)
    expect(result[:sources]).to eq([ { entity_id: entity.id, observation_id: active_observation.id } ])
  end

  it "exposes summarize through the MCP tool" do
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [
        HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.95, matched_fields: [ "name" ])
      ])
    )

    result = SummarizeTool.new.call(query: "GraphMem")

    expect(result[:sources]).not_to be_empty
    expect(result[:summary]).to be_present
  end
end
