# frozen_string_literal: true

require "rails_helper"

RSpec.describe MergeEntitiesTool, type: :model do
  let(:tool) { described_class.new }

  let!(:target) { MemoryEntity.create!(name: "MergeTarget", entity_type: "Task") }
  let!(:source) { MemoryEntity.create!(name: "MergeSource", entity_type: "Task") }

  before do
    MemoryObservation.create!(memory_entity: source, content: "source observation")
  end

  describe "class methods" do
    it ".tool_name returns 'merge_entities'" do
      expect(described_class.tool_name).to eq("merge_entities")
    end

    it ".description returns a non-empty description" do
      expect(tool.description).to be_a(String)
      expect(tool.description).not_to be_empty
    end
  end

  describe "#call" do
    it "merges the source entity into the target" do
      result = tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(result[:status]).to eq("merged")
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
      expect(target.reload.memory_observations.pluck(:content)).to include("source observation")
      expect(target.aliases).to include("MergeSource")
    end

    it "returns source and target IDs in the result" do
      result = tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(result[:source_entity_id]).to eq(source.id)
      expect(result[:target_entity_id]).to eq(target.id)
    end

    it "raises when source and target are the same" do
      expect {
        tool.call(source_entity_id: target.id, target_entity_id: target.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /Cannot merge a node into itself/)
    end

    it "rejects merging away a Project root entity" do
      project_source = MemoryEntity.create!(name: "ProjectSource", entity_type: "Project")

      expect {
        tool.call(source_entity_id: project_source.id, target_entity_id: target.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /Project root entities cannot be deleted or merged away/)

      expect(MemoryEntity.find_by(id: project_source.id)).to be_present
    end

    it "rejects merging entities of different types" do
      project_target = MemoryEntity.create!(name: "ProjectTarget", entity_type: "Project")

      expect {
        tool.call(source_entity_id: source.id, target_entity_id: project_target.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /Cannot merge entities of different types/)

      expect(MemoryEntity.find_by(id: source.id)).to be_present
      expect(MemoryEntity.find_by(id: project_target.id)).to be_present
    end

    it "raises when source entity does not exist" do
      expect {
        tool.call(source_entity_id: 999_999, target_entity_id: target.id)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /Source node not found/)
    end

    it "raises when target entity does not exist" do
      expect {
        tool.call(source_entity_id: source.id, target_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::InternalServerError, /Target node not found/)
    end

    it "transfers all observations from source to target" do
      MemoryObservation.create!(memory_entity: source, content: "second observation")
      MemoryObservation.create!(memory_entity: source, content: "third observation")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(target.reload.memory_observations.pluck(:content)).to contain_exactly(
        "source observation", "second observation", "third observation"
      )
    end

    it "preserves existing target observations" do
      MemoryObservation.create!(memory_entity: target, content: "target observation")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(target.reload.memory_observations.pluck(:content)).to include("target observation", "source observation")
    end

    it "updates the target counter cache after merge" do
      MemoryObservation.create!(memory_entity: source, content: "second observation")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(target.reload.memory_observations_count).to eq(2)
    end

    it "merges source aliases into target aliases" do
      source_with_aliases = MemoryEntity.create!(
        name: "SourceWithAliases",
        entity_type: "Task",
        aliases: "alias1|alias2"
      )

      tool.call(source_entity_id: source_with_aliases.id, target_entity_id: target.id)

      target_aliases = target.reload.aliases.to_s.split(/[,|]/).map(&:strip)
      expect(target_aliases).to include("alias1", "alias2", "SourceWithAliases")
    end

    it "re-parents outgoing relations from source to target" do
      third = MemoryEntity.create!(name: "ThirdEntity", entity_type: "Task")
      MemoryRelation.create!(from_entity: source, to_entity: third, relation_type: "relates_to")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(MemoryRelation.exists?(from_entity_id: target.id, to_entity_id: third.id, relation_type: "relates_to")).to be true
      expect(MemoryRelation.exists?(from_entity_id: source.id)).to be false
    end

    it "re-parents incoming relations from source to target" do
      third = MemoryEntity.create!(name: "ThirdEntity", entity_type: "Task")
      MemoryRelation.create!(from_entity: third, to_entity: source, relation_type: "relates_to")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(MemoryRelation.exists?(from_entity_id: third.id, to_entity_id: target.id, relation_type: "relates_to")).to be true
      expect(MemoryRelation.exists?(to_entity_id: source.id)).to be false
    end

    it "removes direct relations between source and target" do
      MemoryRelation.create!(from_entity: source, to_entity: target, relation_type: "relates_to")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(MemoryRelation.exists?(from_entity_id: source.id, to_entity_id: target.id)).to be false
      expect(MemoryRelation.exists?(from_entity_id: target.id, to_entity_id: source.id)).to be false
    end

    it "deduplicates colliding relations after merge" do
      third = MemoryEntity.create!(name: "ThirdEntity", entity_type: "Task")
      MemoryRelation.create!(from_entity: source, to_entity: third, relation_type: "relates_to")
      MemoryRelation.create!(from_entity: target, to_entity: third, relation_type: "relates_to")

      tool.call(source_entity_id: source.id, target_entity_id: target.id)

      count = MemoryRelation.where(from_entity_id: target.id, to_entity_id: third.id, relation_type: "relates_to").count
      expect(count).to eq(1)
    end
  end
end
