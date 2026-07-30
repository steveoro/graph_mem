# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphIntegrityService do
  before do
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
  end

  describe ".call" do
    it "runs relation integrity repair and garbage collection" do
      result = described_class.call

      expect(result[:relation_integrity]).to be_a(RelationIntegrityRepairer::Result)
      expect(result[:garbage_collection]).to eq({ reports: [], audit_logs_pruned: 0 })
    end

    it "returns counters_repaired count" do
      entity = MemoryEntity.create!(name: "CounterEntity", entity_type: "Task")
      MemoryObservation.create!(memory_entity: entity, content: "one")
      MemoryObservation.create!(memory_entity: entity, content: "two")
      entity.update_column(:memory_observations_count, 99)

      result = described_class.call

      expect(entity.reload.memory_observations_count).to eq(2)
      expect(result[:counters_repaired]).to be >= 1
    end

    it "returns dangling_relations_removed count" do
      entity = MemoryEntity.create!(name: "DanglingEntity", entity_type: "Task")
      other = MemoryEntity.create!(name: "DanglingOther", entity_type: "Task")
      relation = MemoryRelation.create!(from_entity: entity, to_entity: other, relation_type: "relates_to")

      # Simulate a dangling relation by deleting the target entity via raw SQL
      # with FK checks disabled to bypass dependent: :destroy
      ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 0")
      begin
        ActiveRecord::Base.connection.execute("DELETE FROM memory_entities WHERE id = #{other.id}")
      ensure
        ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 1")
      end

      result = described_class.call

      expect(result[:dangling_relations_removed]).to be >= 1
      expect(MemoryRelation.find_by(id: relation.id)).to be_nil
    end

    it "returns embeddings_backfilled result" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:embed_entity).and_return(true)
      allow(EmbeddingService).to receive(:embed_observation).and_return(true)

      MemoryEntity.create!(name: "EmbedEntity", entity_type: "Task")

      result = described_class.call

      expect(result[:embeddings_backfilled]).to include(:backfilled, :failed)
    end

    it "returns failed entities when embedding backfill fails" do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:embed_entity).and_return(false)
      allow(EmbeddingService).to receive(:embed_observation).and_return(true)

      MemoryEntity.create!(name: "FailedEmbedEntity", entity_type: "Task")

      result = described_class.call

      expect(result[:embeddings_backfilled][:failed]).not_to be_empty
      expect(result[:embeddings_backfilled][:failed].first).to include(:entity_id, :name)
    end

    it "returns empty lifecycle issues when observations are clean" do
      entity = MemoryEntity.create!(name: "CleanEntity", entity_type: "Task")
      MemoryObservation.create!(memory_entity: entity, content: "clean observation")

      result = described_class.call

      expect(result[:observation_lifecycle_issues]).to eq([])
    end

    it "detects active observations with obsoleted_at set" do
      entity = MemoryEntity.create!(name: "LifecycleEntity", entity_type: "Task")
      obs = MemoryObservation.create!(memory_entity: entity, content: "corrupted active")
      # Bypass validation with raw SQL
      ActiveRecord::Base.connection.execute(
        "UPDATE memory_observations SET obsoleted_at = NOW() WHERE id = #{obs.id}"
      )

      result = described_class.call

      issues = result[:observation_lifecycle_issues]
      found = issues.find { |i| i[:observation_id] == obs.id }
      expect(found).to be_present
      expect(found[:issue]).to include("active observation has obsoleted_at")
    end

    it "detects superseded observations without superseded_by" do
      entity = MemoryEntity.create!(name: "SupersededEntity", entity_type: "Task")
      obs = MemoryObservation.create!(memory_entity: entity, content: "orphaned supersede")
      # Bypass validation with raw SQL to set superseded status without superseded_by
      ActiveRecord::Base.connection.execute(
        "UPDATE memory_observations SET status = 'superseded', obsoleted_at = NOW() WHERE id = #{obs.id}"
      )

      result = described_class.call

      issues = result[:observation_lifecycle_issues]
      found = issues.find { |i| i[:observation_id] == obs.id }
      expect(found).to be_present
      expect(found[:issue]).to include("no superseded_by reference")
    end

    it "detects cross-entity superseded_by references" do
      entity_a = MemoryEntity.create!(name: "CrossEntityA", entity_type: "Task")
      entity_b = MemoryEntity.create!(name: "CrossEntityB", entity_type: "Task")
      obs_a = MemoryObservation.create!(memory_entity: entity_a, content: "original on A")
      obs_b = MemoryObservation.create!(memory_entity: entity_b, content: "replacement on B")
      # Bypass validation to set superseded_by to an observation on a different entity
      ActiveRecord::Base.connection.execute(
        "UPDATE memory_observations SET status = 'superseded', obsoleted_at = NOW(), superseded_by_id = #{obs_b.id} WHERE id = #{obs_a.id}"
      )

      result = described_class.call

      issues = result[:observation_lifecycle_issues]
      found = issues.find { |i| i[:observation_id] == obs_a.id }
      expect(found).to be_present
      expect(found[:issue]).to include("references a different entity")
    end

    it "logs and continues if relation integrity repair fails" do
      allow(RelationIntegrityRepairer).to receive(:call).and_raise(StandardError, "relation boom")

      expect(Rails.logger).to receive(:error).with(/Relation integrity repair failed/)

      result = described_class.call

      expect(result[:relation_integrity]).to eq({ error: "relation boom", error_class: "StandardError" })
    end
  end
end
