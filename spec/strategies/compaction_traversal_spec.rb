# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionTraversal, type: :model do
  let(:traversal) { described_class.new }

  describe "#entity_ids_for_phase" do
    let!(:project) { MemoryEntity.create!(name: "TraverseProject", entity_type: "Project") }
    let!(:child) { MemoryEntity.create!(name: "TraverseChild", entity_type: "Task") }
    let!(:orphan) { MemoryEntity.create!(name: "TraverseOrphan", entity_type: "Task") }

    before do
      MemoryRelation.create!(from_entity: child, to_entity: project, relation_type: "part_of")
    end

    it "lists orphan entities first in the orphans phase" do
      expect(traversal.entity_ids_for_phase("orphans")).to include(orphan.id)
      expect(traversal.entity_ids_for_phase("orphans")).not_to include(project.id)
    end

    it "walks project roots and children in tree_walk phase" do
      ids = traversal.entity_ids_for_phase("tree_walk")
      expect(ids).to eq([ project.id, child.id ])
    end
  end

  describe "#next_phase_after" do
    it "returns tree_walk after orphans" do
      expect(traversal.next_phase_after("orphans")).to eq("tree_walk")
    end

    it "returns nil after the final phase" do
      expect(traversal.next_phase_after("tree_walk")).to be_nil
    end
  end
end
