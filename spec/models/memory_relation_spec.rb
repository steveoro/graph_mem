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

    it "stores an unmapped relation type folded" do
      rel = described_class.create!(
        from_entity: entity_a,
        to_entity: entity_b,
        relation_type: "Custom Link"
      )

      expect(rel.relation_type).to eq("custom_link")
    end

    it "canonicalizes a code-vocabulary variant with an empty mapping table" do
      expect(RelationTypeMapping.count).to eq(0)

      rel = described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "Calls-Method")

      expect(rel.relation_type).to eq("calls")
    end

    it "keeps a case-only variant of a canonical type" do
      rel = described_class.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "Depends_On")

      expect(rel.relation_type).to eq("depends_on")
    end

    it "keeps presence validation for a blank type" do
      rel = described_class.new(from_entity: entity_a, to_entity: entity_b, relation_type: "  ")

      expect(rel).not_to be_valid
      expect(rel.errors[:relation_type]).to be_present
    end
  end

  describe ".fold_relation_type" do
    it "trims, lower-cases and joins runs of spaces and hyphens with one underscore" do
      expect(described_class.fold_relation_type("Has Many")).to eq("has_many")
      expect(described_class.fold_relation_type("has-many")).to eq("has_many")
      expect(described_class.fold_relation_type(" HAS  many ")).to eq("has_many")
      expect(described_class.fold_relation_type("a - b--c")).to eq("a_b_c")
    end

    it "keeps other characters as they are" do
      expect(described_class.fold_relation_type("Synth::Link.v2")).to eq("synth::link.v2")
    end
  end

  describe ".canonical_relation_type" do
    it "returns the canonical type for folded spellings of a code variant" do
      expect(described_class.canonical_relation_type("Has Many")).to eq("has_many")
      expect(described_class.canonical_relation_type("Is-Part-Of")).to eq("part_of")
      expect(described_class.canonical_relation_type(" HAS  and  belongs to many")).to eq("has_many")
    end

    it "lets a table row beat the code mapping" do
      RelationTypeMapping.create!(canonical_type: "relates_to", variant: "requires")

      expect(described_class.canonical_relation_type("Requires")).to eq("relates_to")
    end

    it "resolves a table variant stored with a space or a hyphen" do
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "needs synth")
      RelationTypeMapping.create!(canonical_type: "calls", variant: "pings-synth")

      expect(described_class.canonical_relation_type("Needs Synth")).to eq("depends_on")
      expect(described_class.canonical_relation_type("needs_synth")).to eq("depends_on")
      expect(described_class.canonical_relation_type("pings-synth")).to eq("calls")
      expect(described_class.canonical_relation_type("PINGS SYNTH")).to eq("calls")
    end

    it "maps a canonical type to itself" do
      expect(described_class.canonical_relation_type("depends_on")).to eq("depends_on")
    end

    it "returns the folded type when nothing maps" do
      expect(described_class.canonical_relation_type(" Novel  Synth-Link ")).to eq("novel_synth_link")
    end

    it "returns a blank type as it came" do
      expect(described_class.canonical_relation_type(nil)).to be_nil
      expect(described_class.canonical_relation_type("  ")).to eq("  ")
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
