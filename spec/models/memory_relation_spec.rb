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

    it "accepts structured metadata" do
      rel = described_class.new(
        from_entity: entity_a,
        to_entity: entity_b,
        relation_type: "depends_on",
        weight: 2.5,
        confidence: 0.75,
        properties: { "evidence" => "operator" }
      )

      expect(rel).to be_valid
    end

    it "validates relation metadata ranges and shape" do
      rel = described_class.new(
        from_entity: entity_a,
        to_entity: entity_b,
        relation_type: "depends_on",
        weight: -1,
        confidence: 1.1,
        properties: []
      )

      expect(rel).not_to be_valid
      expect(rel.errors[:weight]).to be_present
      expect(rel.errors[:confidence]).to be_present
      expect(rel.errors[:properties]).to include("must be an object")
    end
  end

  describe "relation type canonicalization" do
    it "canonicalizes mapped relation type variants before validation" do
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")

      rel = described_class.create!(
        from_entity: entity_a,
        to_entity: entity_b,
        relation_type: "REQUIRES"
      )

      expect(rel.relation_type).to eq("depends_on")
    end

    it "preserves unmapped relation types" do
      rel = described_class.create!(
        from_entity: entity_a,
        to_entity: entity_b,
        relation_type: "custom_link"
      )

      expect(rel.relation_type).to eq("custom_link")
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
