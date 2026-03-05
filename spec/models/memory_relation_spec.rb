# frozen_string_literal: true

require "rails_helper"

RSpec.describe MemoryRelation, type: :model do
  let!(:entity_a) { MemoryEntity.create!(name: "RelEntity A", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "RelEntity B", entity_type: "Task") }

  describe "associations" do
    it "belongs to from_entity" do
      rel = described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")
      expect(rel.from_entity).to eq(entity_a)
    end

    it "belongs to to_entity" do
      rel = described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")
      expect(rel.to_entity).to eq(entity_b)
    end
  end

  describe "validations" do
    it "requires relation_type to be present" do
      rel = described_class.new(from_entity: entity_a, to_entity: entity_b, relation_type: nil)
      expect(rel).not_to be_valid
      expect(rel.errors[:relation_type]).to include("can't be blank")
    end

    it "is valid with from_entity, to_entity, and relation_type" do
      rel = described_class.new(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      expect(rel).to be_valid
    end
  end

  describe "uniqueness constraint" do
    it "allows different relation types between the same entities" do
      described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")
      rel2 = described_class.new(from_entity: entity_a, to_entity: entity_b, relation_type: "depends_on")
      expect(rel2).to be_valid
    end

    it "rejects duplicate from/to/type combinations at the database level" do
      described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")
      expect {
        described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "part_of")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "Auditable concern" do
    it "creates an audit log on creation" do
      expect {
        described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "relates_to")
      }.to change(AuditLog, :count).by(1)
    end
  end
end
