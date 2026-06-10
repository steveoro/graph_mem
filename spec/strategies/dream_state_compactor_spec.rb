# frozen_string_literal: true

require "rails_helper"

RSpec.describe DreamStateCompactor, type: :model do
  let(:run) do
    CompactionRun.create!(
      status: "running",
      phase: "tree_walk",
      stats: {
        "entities_processed" => 0,
        "observations_deduped" => 0
      },
      started_at: Time.current
    )
  end

  let!(:project) { MemoryEntity.create!(name: "CompactProject", entity_type: "Project") }

  describe "observation deduplication" do
    it "removes byte-identical duplicate observations" do
      MemoryObservation.create!(memory_entity: project, content: "same note")
      MemoryObservation.create!(memory_entity: project, content: "same note")
      MemoryObservation.create!(memory_entity: project, content: "unique note")

      compactor = described_class.new(run: run)
      compactor.send(:dedupe_observations_for_entity, project.id)

      expect(project.memory_observations.pluck(:content)).to match_array([ "same note", "unique note" ])
      expect(run.reload.stats["observations_deduped"]).to eq(1)
    end
  end

  describe "pause handling" do
    it "pauses when pause_requested is set mid-batch" do
      MemoryEntity.create!(name: "CompactOther", entity_type: "Project")
      run.update!(phase: "tree_walk", cursor_entity_id: nil)

      allow_any_instance_of(described_class).to receive(:process_entity_for_phase) do
        run.update!(pause_requested: true)
      end

      result = described_class.new(run: run).process_batch!

      expect(result).to eq(:paused)
      expect(run.reload).to be_paused
    end
  end

  describe "orphan auto-parenting" do
    it "parents orphans with a high-confidence project token match" do
      match_project = MemoryEntity.create!(name: "TraverseProject", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "TraverseProject_orphan", entity_type: "Task")
      orphan_run = CompactionRun.create!(
        status: "running",
        phase: "orphans",
        stats: {},
        started_at: Time.current
      )

      described_class.new(run: orphan_run).send(:process_orphan, orphan.id)

      relation = MemoryRelation.find_by(from_entity: orphan, to_entity: match_project, relation_type: "part_of")
      expect(relation).to be_present
      expect(orphan_run.reload.stats["orphans_parented"]).to eq(1)
    end
  end

  describe "phase completion" do
    it "marks the run completed after the final phase batch" do
      run.update!(phase: "tree_walk", cursor_entity_id: project.id)

      result = described_class.new(run: run).process_batch!

      expect(result).to eq(:completed)
      expect(run.reload.status).to eq("completed")
    end
  end
end
