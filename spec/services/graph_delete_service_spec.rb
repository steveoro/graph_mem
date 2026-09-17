# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphDeleteService do
  let!(:project) { MemoryEntity.create!(name: "Protected project", entity_type: "Project") }
  let!(:first) { MemoryEntity.create!(name: "Delete first", entity_type: "Task") }
  let!(:second) { MemoryEntity.create!(name: "Delete second", entity_type: "Task") }
  let!(:observation) { MemoryObservation.create!(memory_entity: first, content: "Disposable") }
  let!(:relation) { MemoryRelation.create!(from_entity: first, to_entity: second, relation_type: "relates_to") }

  describe ".call" do
    it "applies mixed deletions with per-operation reasons" do
      entity_id = second.id
      relation_id = relation.id

      result = described_class.call(
        operations: [
          { type: "delete_observation", observation_id: observation.id, reason: "Outdated" },
          { type: "delete_relation", relation_id: relation_id, reason: "Wrong edge" },
          { type: "delete_entity", entity_id: entity_id, reason: "Obsolete node" }
        ]
      )

      expect(result[:summary]).to include(
        operations: 3,
        entities_deleted: 1,
        observations_obsoleted: 1,
        relations_deleted: 1,
        entities_merged: 0
      )
      expect(observation.reload.obsolescence_reason).to eq("Outdated")
      expect(
        AuditLog.find_by(auditable_type: "MemoryRelation", auditable_id: relation_id, action: "delete").reason
      ).to eq("Wrong edge")
      expect(
        AuditLog.find_by(auditable_type: "MemoryEntity", auditable_id: entity_id, action: "delete").reason
      ).to eq("Obsolete node")
    end

    it "rolls back earlier operations when a later delete fails" do
      expect {
        described_class.call(
          operations: [
            { type: "delete_observation", observation_id: observation.id, reason: "Rollback" },
            { type: "delete_relation", relation_id: 999_999 }
          ]
        )
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /delete_relation\[1\]/)

      expect(observation.reload.status).to eq(MemoryObservation::ACTIVE_STATUS)
    end

    it "preserves Project-root protection" do
      expect {
        described_class.call(
          operations: [ { type: "delete_entity", entity_id: project.id } ]
        )
      }.to raise_error(McpGraphMemErrors::OperationFailed, /Project root/)

      expect(project.reload).to be_present
    end

    it "delegates entity merges to NodeOperationsStrategy" do
      result = described_class.call(
        operations: [
          { type: "merge_entities", source_entity_id: first.id, target_entity_id: second.id }
        ]
      )

      expect(result[:summary][:entities_merged]).to eq(1)
      expect(MemoryEntity.find_by(id: first.id)).to be_nil
      expect(MemoryEntity.find_by(id: second.id)).to be_present
    end

    it "rejects conflicting entity targets before writing" do
      expect {
        described_class.call(
          operations: [
            { type: "delete_entity", entity_id: first.id },
            { type: "merge_entities", source_entity_id: first.id, target_entity_id: second.id }
          ]
        )
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /same entity/)

      expect(first.reload).to be_present
    end
  end
end
