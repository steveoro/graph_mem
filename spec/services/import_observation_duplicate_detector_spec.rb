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

    it "degrades to exact matching when stored observations are not embedded" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)

      # A deferred backfill (e.g. not yet run after a suppressed import) leaves
      # stored rows unembedded; matching degrades rather than failing.
      result = detector.find_duplicate(entity: entity, content: "Reworded imported fact")
      expect(result.duplicate).to be(false)
    end

    it "compares only against embedded observations with only_embedded (1.76.0: project scans)" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
      MemoryObservation.create!(memory_entity: entity, content: "Unembedded code map fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact")

      scan_detector = described_class.new(embedding_service: embedding_service, threshold: 0.35, only_embedded: true)

      expect(scan_detector.find_duplicate(entity: entity, content: "Reworded imported fact").duplicate).to be(true)
      expect(detector.find_duplicate(entity: entity, content: "Reworded imported fact").duplicate).to be(false)
    end

    it "makes no embedding call with only_embedded when none of the entity's facts is embedded yet" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(false)
      MemoryObservation.create!(memory_entity: entity, content: "Unembedded code map fact")
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)

      scan_detector = described_class.new(embedding_service: embedding_service, threshold: 0.35, only_embedded: true)

      expect(scan_detector.find_duplicate(entity: entity, content: "Reworded imported fact").duplicate).to be(false)
      expect(embedding_service).not_to have_received(:embed!)
    end
  end

  # The membership lock is never held across a network call: an import embeds first, then compares.
  describe "#precompute!" do
    before { MemoryObservation.create!(memory_entity: entity, content: "Existing imported fact") }

    it "embeds each distinct non-blank text once, and find_duplicate then uses that vector without a call" do
      expect(detector.precompute!([ "Reworded imported fact", "", "  ", "Reworded imported fact" ])).to eq(1)
      expect(embedding_service).to have_received(:embed!).once

      result = ProjectMembership.with_membership_lock { detector.find_duplicate(entity: entity, content: "Reworded imported fact") }

      expect(result.duplicate).to be(true)
      expect(embedding_service).to have_received(:embed!).once
      expect(detector.fallback_warning).to be_nil
    end

    it "matches a text it has no vector for exactly only, and sums that up in one warning line" do
      detector.precompute!([ "Reworded imported fact" ])

      2.times { |i| expect(detector.find_duplicate(entity: entity, content: "Unforeseen fact #{i}").duplicate).to be(false) }

      expect(embedding_service).to have_received(:embed!).once
      expect(detector.fallback_warning).to eq("Semantic observation de-duplication matched 2 fact(s) exactly only: " \
                                              "2 whose text was not embedded before the import")
    end

    it "makes no embedding call under the membership lock, even without a precompute" do
      result = ProjectMembership.with_membership_lock { detector.find_duplicate(entity: entity, content: "Reworded imported fact") }

      expect(result.duplicate).to be(false)
      expect(embedding_service).not_to have_received(:embed!)
      expect(detector.fallback_warning).to include("1 whose text was not embedded before the import")
    end

    it "stops at the first failed call: the service is down" do
      allow(embedding_service).to receive(:embed!).and_raise(EmbeddingService::EmbeddingError, "HTTP 503")

      expect(detector.precompute!([ "Reworded imported fact", "Distinct imported fact" ])).to eq(0)
      expect(embedding_service).to have_received(:embed!).once
      %w[Reworded Distinct].each { |word| detector.find_duplicate(entity: entity, content: "#{word} imported fact") }
      expect(detector.fallback_warning).to include("2 because the embedding service failed before the import (HTTP 503)")
    end
  end

  describe "#compares_semantically?" do
    it "wants every stamp, or with only_embedded one" do
      scan_detector = described_class.new(embedding_service: embedding_service, only_embedded: true)

      expect([ [], [ Time.current ], [ Time.current, nil ] ].map { |stamps| detector.compares_semantically?(stamps) }).to eq([ false, true, false ])
      expect([ [], [ nil ], [ Time.current, nil ] ].map { |stamps| scan_detector.compares_semantically?(stamps) }).to eq([ false, false, true ])
    end
  end
end
