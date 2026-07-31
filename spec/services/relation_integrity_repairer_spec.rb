# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationIntegrityRepairer, type: :service do
  let!(:entity_a) { MemoryEntity.create!(name: "Repair A", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "Repair B", entity_type: "Task") }
  let!(:entity_c) { MemoryEntity.create!(name: "Repair C", entity_type: "Task") }

  def create_relation_unchecked!(from:, to:, type:)
    relation = MemoryRelation.new(from_entity: from, to_entity: to, relation_type: type)
    relation.save!(validate: false)
    relation
  end

  describe ".call(dry_run: true)" do
    it "reports issues without deleting relations" do
      rel1 = MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "depends_on")

      child = MemoryEntity.create!(name: "Child", entity_type: "Step")
      create_relation_unchecked!(from: child, to: entity_a, type: "part_of")
      create_relation_unchecked!(from: child, to: entity_b, type: "part_of")

      result = described_class.call(dry_run: true)

      expect(result.dry_run).to be true
      expect(result.deleted_relation_ids).to be_empty
      expect(result.reverse_pairs.size).to eq(1)
      expect(result.merge_collisions.size).to eq(1)
      expect(MemoryRelation.count).to eq(4)
      expect(MemoryRelation.exists?(rel1.id)).to be true
    end
  end

  describe ".call(dry_run: false, review_ambiguous: true)" do
    it "queues ambiguous reverse pairs and merge collisions for review" do
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "depends_on")

      child = MemoryEntity.create!(name: "Collision Child", entity_type: "Step")
      create_relation_unchecked!(from: child, to: entity_a, type: "part_of")
      create_relation_unchecked!(from: child, to: entity_b, type: "part_of")

      result = described_class.call(dry_run: false, review_ambiguous: true)

      expect(result.deleted_relation_ids).to be_empty
      expect(result.review_items.size).to eq(2)
      expect(MemoryRelation.count).to eq(4)
    end
  end

  describe ".call(dry_run: false, review_ambiguous: false)" do
    it "removes reverse pairs keeping the oldest relation" do
      older = MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      newer = MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "depends_on")

      result = described_class.call(dry_run: false, review_ambiguous: false)

      expect(result.deleted_relation_ids).to include(newer.id)
      expect(MemoryRelation.exists?(older.id)).to be true
      expect(MemoryRelation.exists?(newer.id)).to be false
    end

    it "removes merge collisions keeping the oldest parent relation" do
      child = MemoryEntity.create!(name: "Collision Child", entity_type: "Step")
      keep = create_relation_unchecked!(from: child, to: entity_a, type: "part_of")
      extra = create_relation_unchecked!(from: child, to: entity_b, type: "part_of")

      result = described_class.call(dry_run: false, review_ambiguous: false)

      expect(result.merge_collisions.size).to eq(1)
      expect(result.deleted_relation_ids).to include(extra.id)
      expect(MemoryRelation.exists?(keep.id)).to be true
      expect(MemoryRelation.exists?(extra.id)).to be false
    end
  end
end
