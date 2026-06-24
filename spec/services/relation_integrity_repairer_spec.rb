# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationIntegrityRepairer, type: :service do
  let!(:entity_a) { MemoryEntity.create!(name: "Repair A", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "Repair B", entity_type: "Task") }
  let!(:entity_c) { MemoryEntity.create!(name: "Repair C", entity_type: "Task") }

  describe ".call(dry_run: true)" do
    it "reports issues without deleting relations" do
      rel1 = MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "depends_on")

      child = MemoryEntity.create!(name: "Child", entity_type: "Step")
      MemoryRelation.create!(from_entity: child, to_entity: entity_a, relation_type: "part_of")
      MemoryRelation.create!(from_entity: child, to_entity: entity_b, relation_type: "part_of")

      result = described_class.call(dry_run: true)

      expect(result.dry_run).to be true
      expect(result.deleted_relation_ids).to be_empty
      expect(result.reverse_pairs.size).to eq(1)
      expect(result.merge_collisions.size).to eq(1)
      expect(MemoryRelation.count).to eq(4)
      expect(MemoryRelation.exists?(rel1.id)).to be true
    end
  end

  describe ".call(dry_run: false)" do
    it "removes reverse pairs keeping the oldest relation" do
      older = MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "relates_to")
      newer = MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "relates_to")

      result = described_class.call(dry_run: false)

      expect(result.deleted_relation_ids).to include(newer.id)
      expect(MemoryRelation.exists?(older.id)).to be true
      expect(MemoryRelation.exists?(newer.id)).to be false
    end

    it "removes merge collisions keeping the oldest parent relation" do
      child = MemoryEntity.create!(name: "Collision Child", entity_type: "Step")
      keep = MemoryRelation.create!(from_entity: child, to_entity: entity_a, relation_type: "part_of")
      extra = MemoryRelation.create!(from_entity: child, to_entity: entity_b, relation_type: "part_of")

      result = described_class.call(dry_run: false)

      expect(result.merge_collisions.size).to eq(1)
      expect(result.deleted_relation_ids).to include(extra.id)
      expect(MemoryRelation.exists?(keep.id)).to be true
      expect(MemoryRelation.exists?(extra.id)).to be false
    end
  end
end
