# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImportObservationDuplicateDetector, :with_test_embeddings do
  let(:entity) { MemoryEntity.create!(name: "Import Duplicate Detector Project", entity_type: "Project") }
  let(:near_vector) { Array.new(768, 0.1) }
  let(:far_vector) { [ 1.0 ] + Array.new(767, 0.0) }
  let(:embedding_service) do
    EmbeddingService.new(
      config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }
    )
  end
  let(:detector) { described_class.new(embedding_service: embedding_service, threshold: 0.35) }

  before do
    allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
    allow(EmbeddingService).to receive(:instance).and_return(embedding_service)
    allow(embedding_service).to receive(:embed).and_return(near_vector)
    allow(embedding_service).to receive(:embed!).and_return(near_vector)
  end

  describe "#find_duplicate" do
    it "recognizes an exact active-content match without requesting embeddings" do
      observation = MemoryObservation.create!(memory_entity: entity, content: "Exact imported fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

      result = detector.find_duplicate(entity: entity, content: observation.content)

      expect(result).to have_attributes(duplicate: true, observation: observation, distance: 0.0, exact_match: true)
      expect(embedding_service).not_to have_received(:embed!)
    end

    it "recognizes a near semantic match within the configured distance" do
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")
      allow(embedding_service).to receive(:embed!).with("Reworded imported fact").and_return(near_vector)

      result = detector.find_duplicate(entity: entity, content: "Reworded imported fact")

      expect(result.duplicate).to be true
      expect(result.exact_match).to be false
      expect(result.distance).to be <= 0.35
    end

    it "retains an observation outside the configured distance" do
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")
      allow(embedding_service).to receive(:embed!).with("Distinct imported fact").and_return(far_vector)

      result = detector.find_duplicate(entity: entity, content: "Distinct imported fact")

      expect(result.duplicate).to be false
      expect(result.distance).to be > 0.35
    end

    it "rejects semantic comparison when vector support is unavailable" do
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)

      expect {
        detector.find_duplicate(entity: entity, content: "Reworded imported fact")
      }.to raise_error(described_class::UnavailableError, /Embedding vectors are unavailable/)
    end

    it "rejects semantic comparison when stored observations are not embedded" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)

      expect {
        detector.find_duplicate(entity: entity, content: "Reworded imported fact")
      }.to raise_error(described_class::UnavailableError, /without embeddings/)
    end
  end
end
