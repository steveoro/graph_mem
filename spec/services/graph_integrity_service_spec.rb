# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphIntegrityService do
  describe ".call" do
    it "runs relation integrity repair and garbage collection" do
      expect(RelationIntegrityRepairer).to receive(:call).and_call_original
      expect(GarbageCollectionRunner).to receive(:call).and_return({ reports: [] })

      result = described_class.call

      expect(result[:relation_integrity]).to be_a(RelationIntegrityRepairer::Result)
      expect(result[:garbage_collection]).to eq({ reports: [] })
    end

    it "recounts memory_observations_count counters" do
      entity = MemoryEntity.create!(name: "CounterEntity", entity_type: "Task")
      MemoryObservation.create!(memory_entity: entity, content: "one")
      MemoryObservation.create!(memory_entity: entity, content: "two")
      entity.update_column(:memory_observations_count, 99)

      allow(RelationIntegrityRepairer).to receive(:call).and_return(
        RelationIntegrityRepairer::Result.new(
          dry_run: false,
          same_direction_duplicates: [],
          reverse_pairs: [],
          merge_collisions: [],
          deleted_relation_ids: []
        )
      )
      allow(GarbageCollectionRunner).to receive(:call).and_return({ reports: [], audit_logs_pruned: 0 })

      described_class.call

      expect(entity.reload.memory_observations_count).to eq(2)
    end

    it "logs and continues if relation integrity repair fails" do
      allow(RelationIntegrityRepairer).to receive(:call).and_raise(StandardError, "relation boom")
      allow(GarbageCollectionRunner).to receive(:call).and_return({ reports: [], audit_logs_pruned: 0 })

      expect(Rails.logger).to receive(:error).with(/Relation integrity repair failed/)

      result = described_class.call

      expect(result[:relation_integrity]).to eq({ error: "relation boom", error_class: "StandardError" })
    end
  end
end
