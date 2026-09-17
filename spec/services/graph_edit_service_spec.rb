# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphEditService do
  let!(:entity) { MemoryEntity.create!(name: "Editable", entity_type: "Project") }
  let!(:observation) { MemoryObservation.create!(memory_entity: entity, content: "Before") }

  describe ".call" do
    it "updates entities and observations in one atomic batch" do
      result = described_class.call(
        operations: [
          { type: "update_entity", entity_id: entity.id, description: "Updated" },
          { type: "update_observation", observation_id: observation.id, text_content: "After" }
        ]
      )

      expect(result[:summary]).to include(
        operations: 2,
        entities_updated: 1,
        observations_updated: 1,
        observations_superseded: 0
      )
      expect(entity.reload.description).to eq("Updated")
      expect(observation.reload.content).to eq("After")
    end

    it "supports observation supersession" do
      result = described_class.call(
        operations: [
          {
            type: "update_observation",
            observation_id: observation.id,
            text_content: "Replacement",
            supersede: true,
            reason: "Correction"
          }
        ]
      )

      expect(result[:summary][:observations_superseded]).to eq(1)
      expect(observation.reload.status).to eq(MemoryObservation::SUPERSEDED_STATUS)
      expect(observation.superseded_by.content).to eq("Replacement")
    end

    it "rolls back earlier updates when a later operation fails" do
      expect {
        described_class.call(
          operations: [
            { type: "update_entity", entity_id: entity.id, description: "Must rollback" },
            { type: "update_observation", observation_id: 999_999, text_content: "Missing" }
          ]
        )
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /update_observation\[1\]/)

      expect(entity.reload.description).to be_nil
    end

    it "rolls back duplicate supersession targets" do
      expect {
        described_class.call(
          operations: [
            { type: "update_observation", observation_id: observation.id, text_content: "First", supersede: true },
            { type: "update_observation", observation_id: observation.id, text_content: "Second", supersede: true }
          ]
        )
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Inactive/)

      expect(observation.reload.status).to eq(MemoryObservation::ACTIVE_STATUS)
      expect(observation.superseded_by_id).to be_nil
    end
  end
end
