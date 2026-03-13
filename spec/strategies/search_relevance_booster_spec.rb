# frozen_string_literal: true

require "rails_helper"

RSpec.describe SearchRelevanceBooster do
  let!(:project) { MemoryEntity.create!(name: "MyProject", entity_type: "Project") }
  let!(:task) { MemoryEntity.create!(name: "MyTask", entity_type: "Task") }
  let!(:framework) { MemoryEntity.create!(name: "Rails", entity_type: "Framework") }
  let!(:issue) { MemoryEntity.create!(name: "BugReport", entity_type: "Issue") }

  describe ".rank_entity_ids" do
    it "returns empty array for empty input" do
      expect(described_class.rank_entity_ids([], query: "test")).to eq([])
    end

    it "ranks Project entities above Task entities" do
      ids = [ task.id, project.id ]
      ranked = described_class.rank_entity_ids(ids, query: "something")
      expect(ranked.first).to eq(project.id)
    end

    it "ranks exact name matches highest" do
      ids = [ task.id, project.id ]
      ranked = described_class.rank_entity_ids(ids, query: "MyProject")
      expect(ranked.first).to eq(project.id)
    end

    it "boosts entities with the query as a name prefix" do
      prefixed = MemoryEntity.create!(name: "MyTaskExtended", entity_type: "Task")
      no_prefix = MemoryEntity.create!(name: "OtherMyTask", entity_type: "Task")

      ids = [ no_prefix.id, prefixed.id ]
      ranked = described_class.rank_entity_ids(ids, query: "MyTask")
      expect(ranked.first).to eq(prefixed.id)
    ensure
      prefixed&.destroy
      no_prefix&.destroy
    end

    it "boosts entities with more relations (structural importance)" do
      hub = MemoryEntity.create!(name: "HubNode", entity_type: "Task")
      leaf = MemoryEntity.create!(name: "LeafNode", entity_type: "Task")
      5.times do |i|
        target = MemoryEntity.create!(name: "Child#{i}", entity_type: "Task")
        MemoryRelation.create!(from_entity: hub, to_entity: target, relation_type: "part_of")
      end

      ids = [ leaf.id, hub.id ]
      ranked = described_class.rank_entity_ids(ids, query: "something")
      expect(ranked.first).to eq(hub.id)
    end

    context "with context boosting" do
      it "boosts in-context entities" do
        ids = [ task.id, issue.id ]
        ranked = described_class.rank_entity_ids(ids, query: "something", context_entity_ids: [ issue.id ])
        expect(ranked.first).to eq(issue.id)
      end

      it "gives root project entity a stronger boost than children" do
        allow(GraphMemContext).to receive(:current_project_id).and_return(project.id)
        child = MemoryEntity.create!(name: "ChildTask", entity_type: "Task")
        context_ids = [ project.id, child.id ]

        ids = [ child.id, project.id ]
        ranked = described_class.rank_entity_ids(ids, query: "something", context_entity_ids: context_ids)
        expect(ranked.first).to eq(project.id)
      end
    end
  end

  describe "constants" do
    it "defines entity type priority for key types" do
      expect(described_class::ENTITY_TYPE_PRIORITY["Project"]).to eq(1.6)
      expect(described_class::ENTITY_TYPE_PRIORITY["Framework"]).to eq(1.3)
      expect(described_class::ENTITY_TYPE_PRIORITY["Feature"]).to eq(1.15)
    end

    it "has sensible boost values" do
      expect(described_class::EXACT_NAME_MATCH_BONUS).to be > described_class::NAME_PREFIX_MATCH_BONUS
      expect(described_class::CONTEXT_ROOT_BOOST).to be > described_class::CONTEXT_CHILD_BOOST
    end
  end
end
