# frozen_string_literal: true

require "rails_helper"

RSpec.describe MergeEntitiesTool, type: :model do
  let(:tool) { described_class.new }

  let!(:target) { MemoryEntity.create!(name: "MergeTarget", entity_type: "Project") }
  let!(:source) { MemoryEntity.create!(name: "MergeSource", entity_type: "Task") }

  before do
    MemoryObservation.create!(memory_entity: source, content: "source observation")
  end

  describe "#call" do
    it "merges the source entity into the target" do
      result = tool.call(source_entity_id: source.id, target_entity_id: target.id)

      expect(result[:status]).to eq("merged")
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
      expect(target.reload.memory_observations.pluck(:content)).to include("source observation")
      expect(target.aliases).to include("MergeSource")
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
  end
end
