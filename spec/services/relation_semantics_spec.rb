# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationSemantics do
  let!(:project) { MemoryEntity.create!(name: "ProjectA", entity_type: "Project") }
  let!(:child) { MemoryEntity.create!(name: "ChildA", entity_type: "Task") }
  let!(:other) { MemoryEntity.create!(name: "OtherA", entity_type: "Task") }

  describe ".validate_create!" do
    it "rejects self loops" do
      expect {
        described_class.validate_create!(from_entity_id: child.id, to_entity_id: child.id, relation_type: "part_of")
      }.to raise_error(RelationSemantics::ValidationError, /self-referential/)
    end

    it "rejects part_of cycles" do
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")

      expect {
        described_class.validate_create!(from_entity_id: project.id, to_entity_id: child.id, relation_type: "part_of")
      }.to raise_error(RelationSemantics::ValidationError, /cycle/)
    end

    it "allows depends_on without removing hierarchy semantics" do
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")

      expect {
        described_class.validate_create!(from_entity_id: child.id, to_entity_id: other.id, relation_type: "depends_on")
      }.not_to raise_error
    end
  end
end
