# frozen_string_literal: true

require "rails_helper"

RSpec.describe ImportEntityResolver do
  let!(:project) { MemoryEntity.create!(name: "Shared Name", entity_type: "Project") }

  before do
    EntityTypeMapping.find_or_create_by!(variant: "workspace") { |mapping| mapping.canonical_type = "Project" }
  end

  it "canonicalizes imported types before exact matching" do
    expect(described_class.find_by_name_and_type("Shared Name", "workspace")).to eq(project)
  end

  it "does not fall back to an entity with the same name and another type" do
    expect(described_class.find_by_name_and_type("Shared Name", "Task")).to be_nil
  end

  describe ".stored_reference_target" do
    it "filters candidates by the edge's relation types — unrelated edges don't split the vote" do
      other_project = MemoryEntity.create!(name: "OtherProj", entity_type: "Project")
      referrer = MemoryEntity.create!(name: "Ref", entity_type: "Class")
      mixin = MemoryEntity.create!(name: "Foo", entity_type: "Module")
      other = fs_member!(other_project, "Foo", "Class")
      MemoryRelation.create!(from_entity: referrer, to_entity: mixin, relation_type: "mixes_in")
      # An unrelated edge to a SAME-NAMED entity — must not make the
      # lookup ambiguous.
      MemoryRelation.create!(from_entity: referrer, to_entity: other, relation_type: "solves")

      expect(
        described_class.stored_reference_target("Foo", [ referrer.id ], [ "mixes_in" ])
      ).to eq(mixin)
    end

    it "returns nil when two typed edges reach two different namesakes" do
      other_project = MemoryEntity.create!(name: "OtherProj", entity_type: "Project")
      referrer = MemoryEntity.create!(name: "Ref", entity_type: "Class")
      first = MemoryEntity.create!(name: "Foo", entity_type: "Class")
      second = fs_member!(other_project, "Foo", "Class")
      MemoryRelation.create!(from_entity: referrer, to_entity: first, relation_type: "mixes_in")
      fs_member!(second, referrer)

      expect(
        described_class.stored_reference_target("Foo", [ referrer.id ], [ "mixes_in" ])
      ).to be_nil
    end
  end
end
