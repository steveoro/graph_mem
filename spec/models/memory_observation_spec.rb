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
    it "calls EmbeddingService after content changes" do
      service = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed_entity)
      allow(service).to receive(:embed_observation)

      described_class.create!(memory_entity: entity, content: "embed test")
      expect(service).to have_received(:embed_observation)
    end

    it "does not raise when embedding service fails" do
      allow(EmbeddingService).to receive(:instance).and_raise(StandardError, "service down")

      expect {
        described_class.create!(memory_entity: entity, content: "fail gracefully")
      }.not_to raise_error
    end
  end
end
