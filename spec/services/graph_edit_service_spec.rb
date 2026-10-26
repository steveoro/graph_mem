# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphEditService do
  let!(:entity) { MemoryEntity.create!(name: "Editable", entity_type: "Project") }
  let!(:observation) { MemoryObservation.create!(memory_entity: entity, content: "Before") }

  def checkread_error
    mysql_error = Mysql2::Error.new("Record has changed since last read in table 'memory_entities'")
    allow(mysql_error).to receive(:error_number).and_return(TransientDbError::CHECKREAD_ERRNO)
    error = ActiveRecord::StatementInvalid.new(mysql_error.message)
    allow(error).to receive(:cause).and_return(mysql_error)
    error
  end

  # A concurrent writer (merge, undo, another edit) changed a row this edit waited on (UI-4a).
  describe "a write refused by a concurrent writer" do
    def stale_once(times: 1)
      calls = 0
      allow_any_instance_of(MemoryEntity).to receive(:save!).and_wrap_original do |original, *args|
        calls += 1
        raise checkread_error if calls <= times

        original.call(*args)
      end
    end

    it "retries in a fresh transaction and applies the edit" do
      stale_once
      result = described_class.call(operations: [ { type: "update_entity", entity_id: entity.id, description: "after retry" } ])

      expect(result[:status]).to eq("ok")
      expect(entity.reload.description).to eq("after retry")
      expect(ChangeSet.count).to eq(1)
    end

    it "retries the single-operation path too" do
      stale_once
      described_class.execute_one("update_entity", { entity_id: entity.id, description: "after retry" })

      expect(entity.reload.description).to eq("after retry")
    end

    it "answers a retryable concurrency error once the attempts run out" do
      stale_once(times: described_class::TRANSIENT_ATTEMPTS)

      expect { described_class.call(operations: [ { type: "update_entity", entity_id: entity.id, description: "never" } ]) }
        .to raise_error(McpGraphMemErrors::OperationFailed) { |error|
          expect(error).to have_attributes(category: "concurrency", retriable: true, code: "concurrent_write")
        }
      expect(entity.reload.description).to be_nil
    end

    it "doesn't retry inside a caller's transaction" do
      stale_once

      expect do
        ActiveRecord::Base.transaction do
          described_class.call(operations: [ { type: "update_entity", entity_id: entity.id, description: "nested" } ])
        end
      end.to raise_error(McpGraphMemErrors::OperationFailed, /same record at the same time/)
    end
  end

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
      }.to raise_error(GraphMem::InvalidArgumentsError, /Inactive/)

      expect(observation.reload.status).to eq(MemoryObservation::ACTIVE_STATUS)
      expect(observation.superseded_by_id).to be_nil
    end
  end
end
