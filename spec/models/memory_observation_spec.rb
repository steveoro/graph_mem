# frozen_string_literal: true

require "rails_helper"

RSpec.describe MemoryObservation, type: :model do
  let(:entity) { MemoryEntity.create!(name: "TestEntity", entity_type: "Project") }

  describe "associations" do
    it "belongs to a memory_entity" do
      observation = described_class.create!(memory_entity: entity, content: "test obs")
      expect(observation.memory_entity).to eq(entity)
    end

    it "updates the counter cache on the parent entity" do
      expect {
        described_class.create!(memory_entity: entity, content: "counter test")
      }.to change { entity.reload.memory_observations_count }.by(1)
    end

    it "decrements the counter cache when destroyed" do
      obs = described_class.create!(memory_entity: entity, content: "to be deleted")
      expect {
        obs.destroy!
      }.to change { entity.reload.memory_observations_count }.by(-1)
    end

    it "links superseded observations to their replacement" do
      observation = described_class.create!(memory_entity: entity, content: "old")
      replacement = observation.supersede!(content: "new")

      expect(observation.reload.superseded_by).to eq(replacement)
      expect(replacement.superseded_observations).to contain_exactly(observation)
    end
  end

  describe "validations" do
    it "requires content to be present" do
      observation = described_class.new(memory_entity: entity, content: nil)
      expect(observation).not_to be_valid
      expect(observation.errors[:content]).to include("can't be blank")
    end

    it "requires a memory_entity" do
      observation = described_class.new(content: "orphan obs")
      expect(observation).not_to be_valid
      expect(observation.errors[:memory_entity]).to be_present
    end

    it "is valid with content and a memory_entity" do
      observation = described_class.new(memory_entity: entity, content: "valid obs")
      expect(observation).to be_valid
    end

    it "accepts structured metadata" do
      observation = described_class.new(
        memory_entity: entity,
        content: "metadata",
        confidence: 0.8,
        source: "operator",
        valid_from: Time.zone.parse("2026-07-01"),
        valid_until: Time.zone.parse("2026-08-01"),
        tags: %w[verified project]
      )

      expect(observation).to be_valid
    end

    it "requires confidence to be between zero and one" do
      observation = described_class.new(memory_entity: entity, content: "invalid", confidence: 1.1)

      expect(observation).not_to be_valid
      expect(observation.errors[:confidence]).to be_present
    end

    it "requires valid_until to be on or after valid_from" do
      observation = described_class.new(
        memory_entity: entity,
        content: "invalid dates",
        valid_from: Time.zone.parse("2026-08-01"),
        valid_until: Time.zone.parse("2026-07-01")
      )

      expect(observation).not_to be_valid
      expect(observation.errors[:valid_until]).to include("must be on or after valid_from")
    end

    it "requires tags to be an array of strings" do
      observation = described_class.new(memory_entity: entity, content: "invalid tags", tags: [ "valid", 1 ])

      expect(observation).not_to be_valid
      expect(observation.errors[:tags]).to include("must be an array of strings")
    end

    it "requires lifecycle state to be consistent" do
      observation = described_class.new(
        memory_entity: entity,
        content: "invalid lifecycle",
        status: described_class::OBSOLETE_STATUS
      )

      expect(observation).not_to be_valid
      expect(observation.errors[:obsoleted_at]).to be_present
    end

    it "requires a superseding observation from the same entity" do
      other_entity = MemoryEntity.create!(name: "Other", entity_type: "Project")
      replacement = described_class.create!(memory_entity: other_entity, content: "replacement")
      observation = described_class.new(
        memory_entity: entity,
        content: "old",
        status: described_class::SUPERSEDED_STATUS,
        obsoleted_at: Time.current,
        superseded_by: replacement
      )

      expect(observation).not_to be_valid
      expect(observation.errors[:superseded_by]).to include("must belong to the same entity")
    end

    it "prevents an observation from superseding itself" do
      observation = described_class.create!(memory_entity: entity, content: "self")
      observation.assign_attributes(
        status: described_class::SUPERSEDED_STATUS,
        obsoleted_at: Time.current,
        superseded_by: observation
      )

      expect(observation).not_to be_valid
      expect(observation.errors[:superseded_by]).to include("cannot reference itself")
    end
  end

  describe "lifecycle" do
    let(:observation) do
      described_class.create!(
        memory_entity: entity,
        content: "original",
        confidence: 0.7,
        source: "spec",
        tags: [ "current" ]
      )
    end

    it "defaults to active and exposes lifecycle scopes and predicates" do
      obsolete = described_class.create!(memory_entity: entity, content: "obsolete")
      obsolete.mark_obsolete!

      expect(observation).to be_active
      expect(observation).not_to be_obsolete
      expect(described_class.active).to contain_exactly(observation)
      expect(described_class.inactive).to contain_exactly(obsolete)
    end

    it "marks an observation obsolete without deleting it" do
      observation.mark_obsolete!(reason: "Outdated")

      expect(observation).to be_persisted
      expect(observation).to be_obsolete
      expect(observation.obsoleted_at).to be_present
      expect(observation.obsolescence_reason).to eq("Outdated")
      expect(described_class.exists?(observation.id)).to be(true)
    end

    it "is idempotent when marking an inactive observation obsolete" do
      observation.mark_obsolete!(reason: "First reason")
      original_timestamp = observation.obsoleted_at

      expect {
        observation.mark_obsolete!(reason: "Second reason")
      }.not_to change(observation, :updated_at)
      expect(observation.obsoleted_at).to eq(original_timestamp)
      expect(observation.obsolescence_reason).to eq("First reason")
    end

    it "updates active observations in place" do
      result = observation.update_active!(confidence: 0.9)

      expect(result).to eq(observation)
      expect(observation.reload.confidence).to eq(0.9)
      expect(observation).to be_active
    end

    it "supersedes an observation with a replacement that copies unchanged fields" do
      replacement = observation.supersede!(content: "corrected", confidence: 0.95, reason: "Correction")

      expect(replacement).to be_active
      expect(replacement).to have_attributes(
        memory_entity_id: entity.id,
        content: "corrected",
        confidence: 0.95,
        source: "spec",
        tags: [ "current" ]
      )
      expect(observation.reload).to be_superseded
      expect(observation.superseded_by).to eq(replacement)
      expect(observation.obsoleted_at).to be_present
      expect(observation.obsolescence_reason).to eq("Correction")
    end

    it "rejects updates and supersession for inactive observations" do
      observation.mark_obsolete!

      expect {
        observation.update_active!(content: "changed")
      }.to raise_error(described_class::InactiveObservationError)
      expect {
        observation.supersede!(content: "replacement")
      }.to raise_error(described_class::InactiveObservationError)
    end
  end

  describe "#as_json" do
    let(:observation) { described_class.create!(memory_entity: entity, content: "json test") }

    it "excludes the embedding column" do
      json = observation.as_json
      expect(json).not_to have_key("embedding")
    end

    it "includes standard attributes" do
      json = observation.as_json
      expect(json).to have_key("id")
      expect(json).to have_key("content")
      expect(json).to have_key("memory_entity_id")
      expect(json).to have_key("confidence")
      expect(json).to have_key("source")
      expect(json).to have_key("valid_from")
      expect(json).to have_key("valid_until")
      expect(json).to have_key("tags")
      expect(json).to have_key("status")
      expect(json).to have_key("obsoleted_at")
      expect(json).to have_key("obsolescence_reason")
      expect(json).to have_key("superseded_by_id")
      expect(json).to have_key("created_at")
      expect(json).to have_key("updated_at")
    end

    it "preserves caller-specified :except options" do
      json = observation.as_json(except: :created_at)
      expect(json).not_to have_key("embedding")
      expect(json).not_to have_key("created_at")
      expect(json).to have_key("content")
    end

    it "works on a collection" do
      described_class.create!(memory_entity: entity, content: "second obs")
      json = entity.memory_observations.as_json
      json.each do |item|
        expect(item).not_to have_key("embedding")
        expect(item).to have_key("content")
      end
    end
  end

  describe "embedding callback" do
    it "calls embed_observation on create via after_create" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed_observation)
      allow(service).to receive(:embed_entity)

      described_class.create!(memory_entity: entity, content: "embed test")
      expect(service).to have_received(:embed_observation)
    end

    it "calls embed_observation via after_commit on update when content changes" do
      obs = described_class.create!(memory_entity: entity, content: "original")

      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed_observation)

      obs.update!(content: "updated")
      expect(service).to have_received(:embed_observation)
    end

    it "refreshes embeddings when semantic metadata changes" do
      obs = described_class.create!(memory_entity: entity, content: "original")

      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService, embed_observation: nil)
      allow(EmbeddingService).to receive(:instance).and_return(service)

      obs.update!(source: "new source", tags: [ "updated" ])

      expect(service).to have_received(:embed_observation).once
    end

    it "does not refresh embeddings when non-semantic metadata changes" do
      obs = described_class.create!(memory_entity: entity, content: "original")

      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService, embed_observation: nil)
      allow(EmbeddingService).to receive(:instance).and_return(service)

      obs.update!(confidence: 0.9, valid_until: 1.day.from_now)

      expect(service).not_to have_received(:embed_observation)
    end

    it "does not refresh embeddings for lifecycle-only updates" do
      obs = described_class.create!(memory_entity: entity, content: "original")

      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService, embed_observation: nil)
      allow(EmbeddingService).to receive(:instance).and_return(service)

      obs.mark_obsolete!(reason: "Outdated")

      expect(service).not_to have_received(:embed_observation)
    end

    it "does not raise when embedding service fails on create" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_raise(StandardError, "service down")

      expect {
        described_class.create!(memory_entity: entity, content: "fail gracefully")
      }.not_to raise_error
    end
  end
end
