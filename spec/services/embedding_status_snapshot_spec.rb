# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmbeddingStatusSnapshot do
  let!(:entity) { MemoryEntity.create!(name: "EmbedSnapEntity", entity_type: "Project") }

  before do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingIndexStatus).to receive(:indexes).and_return(
      memory_entities: true,
      memory_observations: false
    )
  end

  describe ".call" do
    it "returns coverage and missing counts" do
      snapshot = described_class.call

      expect(snapshot[:entities_total]).to eq(1)
      expect(snapshot[:vector_enabled]).to be true
      expect(snapshot[:config]).to include(:provider, :model, :url, :dims)
      expect(snapshot[:indexes][:memory_entities]).to be true
      expect(snapshot[:coverage_percent]).to be_between(0, 100)
    end

    it "reports vector_search_ready false when indexes or missing rows remain" do
      snapshot = described_class.call

      expect(snapshot[:vector_search_ready]).to be false
    end

    context "when vector columns are disabled" do
      before { allow(EmbeddingService).to receive(:vector_enabled?).and_return(false) }

      it "returns zero coverage and not ready" do
        snapshot = described_class.call

        expect(snapshot[:coverage_percent]).to eq(0)
        expect(snapshot[:vector_search_ready]).to be false
        expect(snapshot[:entities_missing]).to eq(1)
      end
    end
  end
end
