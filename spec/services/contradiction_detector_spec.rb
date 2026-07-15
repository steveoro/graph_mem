# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContradictionDetector do
  let(:entity) { MemoryEntity.create!(name: "ContradictionEntity", entity_type: "Project") }
  let(:fake_vector) { Array.new(768, 0.1) }

  describe ".detect" do
    context "when vector search is disabled" do
      before { allow(EmbeddingService).to receive(:vector_enabled?).and_return(false) }

      it "returns an empty array" do
        expect(described_class.detect(entity.id)).to eq([])
      end
    end

    context "when contradiction detection is disabled" do
      before do
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        allow(AppSettings).to receive(:contradiction_detection_enabled?).and_return(false)
      end

      it "returns an empty array" do
        expect(described_class.detect(entity.id)).to eq([])
      end
    end
  end

  describe "polarity heuristics" do
    it "detects negative wording" do
      expect(described_class.send(:negative?, "This is not supported")).to be true
      expect(described_class.send(:negative?, "This is deprecated")).to be true
    end

    it "does not flag positive wording" do
      expect(described_class.send(:negative?, "This is supported")).to be false
      expect(described_class.send(:negative?, "Feature is active")).to be false
    end

    it "detects polarity conflicts" do
      expect(described_class.send(:polarity_conflict?, "Feature is enabled", "Feature is not enabled")).to be true
      expect(described_class.send(:polarity_conflict?, "Feature is enabled", "Feature is active")).to be false
      expect(described_class.send(:polarity_conflict?, "Not supported", "Never supported")).to be false
    end
  end

  describe "contradiction confidence" do
    it "increases confidence as distance decreases" do
      low_distance = described_class.send(:contradiction_confidence, 0.1)
      high_distance = described_class.send(:contradiction_confidence, 0.3)

      expect(low_distance).to be > high_distance
      expect(low_distance).to be <= 0.99
    end
  end

  describe ".detect with vector embeddings", :with_test_embeddings do
    let(:stubbed_service) do
      service = EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 })
      allow(service).to receive(:embed).and_return(fake_vector)
      service
    end

    before do
      EmbeddingService.reset_vector_cache!
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_return(stubbed_service)
    end

    after do
      EmbeddingService.reset_vector_cache!
    end

    it "returns candidate pairs for semantically similar observations with opposite polarity" do
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is enabled")
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is not enabled")

      result = described_class.detect(entity.id, max_distance: 0.35, max_results: 10)

      expect(result).not_to be_empty
      expect(result.first).to have_attributes(
        observation_id_1: be_a(Integer),
        observation_id_2: be_a(Integer),
        distance: be_a(Numeric),
        confidence: be_a(Numeric)
      )
    end

    it "does not flag observations with the same polarity" do
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is enabled")
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is active")

      result = described_class.detect(entity.id, max_distance: 0.35, max_results: 10)

      expect(result).to be_empty
    end

    it "persists a contradictions maintenance report" do
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is enabled")
      MemoryObservation.create!(memory_entity: entity, content: "Feature X is not enabled")

      expect {
        described_class.detect(entity.id, max_distance: 0.35, max_results: 10)
      }.to change { MaintenanceReport.by_type("contradictions").count }.by(1)
    end

    it "includes 1-hop related entity observations" do
      related = MemoryEntity.create!(name: "Related", entity_type: "Task")
      MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: related.id, relation_type: "relates_to")

      MemoryObservation.create!(memory_entity: entity, content: "Feature X is enabled")
      MemoryObservation.create!(memory_entity: related, content: "Feature X is not enabled")

      result = described_class.detect(entity.id, max_distance: 0.35, max_results: 10)

      expect(result).not_to be_empty
    end
  end
end
