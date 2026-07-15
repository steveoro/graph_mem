# frozen_string_literal: true

require "rails_helper"

RSpec.describe SummarizeTool, type: :model do
  let(:tool) { described_class.new }

  let!(:entity) do
    MemoryEntity.create!(name: "GraphMem", entity_type: "Project")
  end

  let!(:observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "GraphMem supports hybrid search and trust scores."
    )
  end

  before do
    AppSettings.clear_cache
    AppSettings.enable_llm_summarization = false
  end

  after { AppSettings.clear_cache }

  describe ".tool_name" do
    it "returns summarize" do
      expect(described_class.tool_name).to eq("summarize")
    end
  end

  describe "#call" do
    it "returns a sourced deterministic summary" do
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.8, matched_fields: [ "name" ])
        ])
      )

      result = tool.call(query: "GraphMem capabilities")

      expect(result[:generation_mode]).to eq("deterministic")
      expect(result[:sources]).to include(entity_id: entity.id, observation_id: observation.id)
    end

    it "raises ResourceNotFound for missing entity_id" do
      expect {
        tool.call(query: "GraphMem", entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound)
    end
  end
end
