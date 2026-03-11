# frozen_string_literal: true

require "rails_helper"

RSpec.describe MemoryEntity, type: :model do
  describe "associations" do
    let(:entity) { described_class.create!(name: "AssocEntity", entity_type: "Project") }

    it "has many memory_observations" do
      obs = MemoryObservation.create!(memory_entity: entity, content: "obs 1")
      expect(entity.memory_observations).to include(obs)
    end

    it "destroys dependent observations" do
      MemoryObservation.create!(memory_entity: entity, content: "dependent obs")
      expect { entity.destroy! }.to change(MemoryObservation, :count).by(-1)
    end

    it "has many relations_from (outbound)" do
      other = described_class.create!(name: "OtherTo", entity_type: "Task")
      rel = MemoryRelation.create!(from_entity: entity, to_entity: other, relation_type: "depends_on")
      expect(entity.relations_from).to include(rel)
    end

    it "has many relations_to (inbound)" do
      other = described_class.create!(name: "OtherFrom", entity_type: "Task")
      rel = MemoryRelation.create!(from_entity: other, to_entity: entity, relation_type: "part_of")
      expect(entity.relations_to).to include(rel)
    end

    it "destroys dependent relations on delete" do
      other = described_class.create!(name: "RelCleanup", entity_type: "Task")
      MemoryRelation.create!(from_entity: entity, to_entity: other, relation_type: "part_of")
      MemoryRelation.create!(from_entity: other, to_entity: entity, relation_type: "depends_on")
      expect { entity.destroy! }.to change(MemoryRelation, :count).by(-2)
    end
  end

  describe "validations" do
    it "requires name to be present" do
      entity = described_class.new(name: nil, entity_type: "Project")
      expect(entity).not_to be_valid
      expect(entity.errors[:name]).to include("can't be blank")
    end

    it "requires name to be unique" do
      described_class.create!(name: "Unique", entity_type: "Project")
      duplicate = described_class.new(name: "Unique", entity_type: "Task")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "requires entity_type to be present" do
      entity = described_class.new(name: "NoType", entity_type: nil)
      expect(entity).not_to be_valid
      expect(entity.errors[:entity_type]).to include("can't be blank")
    end

    it "is valid with name and entity_type" do
      entity = described_class.new(name: "ValidEntity", entity_type: "Project")
      expect(entity).to be_valid
    end
  end

  describe "defaults" do
    it "initializes memory_observations_count to 0" do
      entity = described_class.new
      expect(entity.memory_observations_count).to eq(0)
    end

    it "does not overwrite an existing counter value" do
      entity = described_class.new(memory_observations_count: 5)
      expect(entity.memory_observations_count).to eq(5)
    end
  end

  describe "entity_type canonicalization" do
    it "canonicalizes entity_type via EntityTypeMapping on validation" do
      EntityTypeMapping.create!(canonical_type: "Project", variant: "proj")
      entity = described_class.create!(name: "Canonical", entity_type: "proj")
      expect(entity.entity_type).to eq("Project")
    end

    it "leaves entity_type unchanged when no mapping exists" do
      entity = described_class.create!(name: "NoMapping", entity_type: "CustomType")
      expect(entity.entity_type).to eq("CustomType")
    end
  end

  describe "#as_json" do
    let(:entity) { described_class.create!(name: "JsonEntity", entity_type: "Project") }

    it "excludes the embedding column" do
      json = entity.as_json
      expect(json).not_to have_key("embedding")
    end

    it "includes standard attributes" do
      json = entity.as_json
      expect(json).to have_key("id")
      expect(json).to have_key("name")
      expect(json).to have_key("entity_type")
      expect(json).to have_key("memory_observations_count")
      expect(json).to have_key("created_at")
      expect(json).to have_key("updated_at")
    end

    it "preserves caller-specified :except options" do
      json = entity.as_json(except: :created_at)
      expect(json).not_to have_key("embedding")
      expect(json).not_to have_key("created_at")
      expect(json).to have_key("name")
    end

    it "works on a collection" do
      described_class.create!(name: "JsonEntity2", entity_type: "Task")
      json = described_class.all.as_json
      json.each do |item|
        expect(item).not_to have_key("embedding")
        expect(item).to have_key("name")
      end
    end
  end

  describe "embedding callback" do
    it "calls embed_entity on create via after_create" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed_entity)

      described_class.create!(name: "EmbedCallback", entity_type: "Project")
      expect(service).to have_received(:embed_entity)
    end

    it "calls embed_entity via after_commit on update when embedding fields change" do
      entity = described_class.create!(name: "EmbedUpdate", entity_type: "Project")

      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      service = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed_entity)

      entity.update!(name: "EmbedUpdated")
      expect(service).to have_received(:embed_entity)
    end

    it "does not raise when embedding service fails on create" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_raise(StandardError, "service down")

      expect {
        described_class.create!(name: "EmbedFail", entity_type: "Project")
      }.not_to raise_error
    end
  end
end
