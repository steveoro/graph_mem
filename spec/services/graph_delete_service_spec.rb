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

    it "refuses an empty Project unless allow_empty_project_delete is set" do
      expect {
        described_class.call(operations: [ { type: "delete_entity", entity_id: project.id } ])
      }.to raise_error(McpGraphMemErrors::OperationFailed, /maintenance profile/) { |error|
        expect(error.code).to eq("project_delete_needs_maintenance")
      }
      expect(project.reload).to be_present
    end

    it "deletes an empty Project with allow_empty_project_delete and clears contexts pointing at it" do
      AgentContext.create!(client_id: "delete-spec-#{SecureRandom.hex(4)}", current_project_id: project.id)

      result = described_class.call(
        operations: [ { type: "delete_entity", entity_id: project.id } ], allow_empty_project_delete: true
      )

      expect(result[:summary][:entities_deleted]).to eq(1)
      expect(MemoryEntity.find_by(id: project.id)).to be_nil
      expect(AgentContext.where(current_project_id: project.id)).to be_empty
    end

    it "refuses a Project with members even with allow_empty_project_delete" do
      first.update!(project_id: project.id)

      expect {
        described_class.call(
          operations: [ { type: "delete_entity", entity_id: project.id } ], allow_empty_project_delete: true
        )
      }.to raise_error(McpGraphMemErrors::OperationFailed, /1 member entities/) { |error|
        expect(error.code).to eq("project_has_members")
      }
      expect(project.reload).to be_present
    end

    it "maps a member committed after the count (FK refusal) to project_has_members" do
      allow_any_instance_of(MemoryEntity).to receive(:destroy!).and_raise(ActiveRecord::InvalidForeignKey, "fk")

      expect {
        described_class.call(
          operations: [ { type: "delete_entity", entity_id: project.id } ], allow_empty_project_delete: true
        )
      }.to raise_error(McpGraphMemErrors::OperationFailed, /just added/) { |error|
        expect(error.code).to eq("project_has_members")
      }
    end

    it "rolls back the whole batch and keeps the code when a later Project delete is refused" do
      first.update!(project_id: project.id)
      relation_id = relation.id

      expect {
        described_class.call(
          operations: [
            { type: "delete_relation", relation_id: relation_id },
            { type: "delete_entity", entity_id: project.id }
          ],
          allow_empty_project_delete: true
        )
      }.to raise_error(McpGraphMemErrors::OperationFailed, /\Adelete_entity\[1\]: /) { |error|
        expect(error.code).to eq("project_has_members")
      }
      expect(MemoryRelation.exists?(relation_id)).to be(true)
    end

    it "deletes the last member and then its Project in one maintenance batch" do
      first.update!(project_id: project.id)

      result = described_class.call(
        operations: [
          { type: "delete_entity", entity_id: first.id },
          { type: "delete_entity", entity_id: project.id }
        ],
        allow_empty_project_delete: true
      )

      expect(result[:summary][:entities_deleted]).to eq(2)
      expect(MemoryEntity.where(id: [ first.id, project.id ])).to be_empty
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

  it "reports counts equal to the rows actually deleted (PR-2 §2.8)" do
    target = MemoryEntity.create!(name: "SynthWidget Delete", entity_type: "Component")
    other = MemoryEntity.create!(name: "Alpha Service Delete", entity_type: "Service")
    2.times { |i| target.memory_observations.create!(content: "fact #{i}") }
    MemoryRelation.create!(from_entity_id: target.id, to_entity_id: other.id, relation_type: "depends_on")
    before = [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count ]

    summary = described_class.call(operations: [ { type: "delete_entity", entity_id: target.id } ])[:summary]

    expect(summary).to include(
      entities_deleted: before[0] - MemoryEntity.count,
      observations_deleted: before[1] - MemoryObservation.count,
      relations_deleted: before[2] - MemoryRelation.count
    )
    expect(summary).to include(entities_deleted: 1, observations_deleted: 2, relations_deleted: 1)
  end
end
