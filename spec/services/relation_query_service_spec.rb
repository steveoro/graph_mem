# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationQueryService do
  let!(:first) { MemoryEntity.create!(name: "Relation first", entity_type: "Project") }
  let!(:second) { MemoryEntity.create!(name: "Relation second", entity_type: "Task") }
  let!(:third) { MemoryEntity.create!(name: "Relation third", entity_type: "Issue") }
  let!(:first_relation) do
    MemoryRelation.create!(from_entity: first, to_entity: second, relation_type: "depends_on")
  end
  let!(:second_relation) do
    MemoryRelation.create!(from_entity: second, to_entity: third, relation_type: "part_of")
  end

  describe ".call" do
    it "supports global and endpoint relation queries" do
      expect(described_class.call.pluck(:relation_id)).to contain_exactly(
        first_relation.id,
        second_relation.id
      )
      expect(
        described_class.call(from_entity_id: first.id).pluck(:relation_id)
      ).to eq([ first_relation.id ])
      expect(
        described_class.call(to_entity_id: third.id).pluck(:relation_id)
      ).to eq([ second_relation.id ])
    end

    it "canonicalizes singular and plural relation types" do
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")

      singular = described_class.call(relation_type: "REQUIRES")
      plural = described_class.call(relation_types: %w[requires part_of])

      expect(singular.pluck(:relation_id)).to eq([ first_relation.id ])
      expect(plural.pluck(:relation_id)).to contain_exactly(first_relation.id, second_relation.id)
    end

    it "rejects missing endpoint entities with canonical guidance" do
      expect {
        described_class.call(from_entity_id: 999_999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound) do |error|
        expect(error.next_move).to include("search")
        expect(error.next_move).to include("traverse_graph")
      end
    end
  end
end
