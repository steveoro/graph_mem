# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the orphan rule (an entity a Project depends_on is no orphan), phase 1's "add"
# rows for a dependency-like orphan, and the dream-state actor on the auto-parent.
RSpec.describe DreamStateCompactor, "dependency-like orphans" do
  let!(:synth_app) { fs_project!("SynthApp") }

  after { CompactionRun.delete_all }

  def orphan_run = CompactionRun.create!(status: "running", phase: "orphans", stats: {}, started_at: Time.current)

  def compact(run = orphan_run)
    compactor = described_class.new(run: run)
    compactor.process_batch! until run.reload.phase != "orphans" || run.completed?
    run
  end

  describe "the orphan rule" do
    it "leaves out an entity a Project depends_on, wherever the orphan list is read" do
      depended = MemoryEntity.create!(name: "SynthLib", entity_type: "Gem")
      MemoryRelation.create!(from_entity: synth_app, to_entity: depended, relation_type: "depends_on")
      used_by_other = MemoryEntity.create!(name: "SynthHelper", entity_type: "Gem")
      MemoryRelation.create!(from_entity: MemoryEntity.create!(name: "SynthTask", entity_type: "Task"), to_entity: used_by_other,
                             relation_type: "depends_on")

      ids = OrphanMatchingStrategy.new.orphan_nodes.pluck(:id)

      expect(ids).to include(used_by_other.id)
      expect(ids).not_to include(depended.id, synth_app.id)
      expect(OrphanMatchingStrategy.new.orphans_with_matches.map { |orphan| orphan[:id] }).not_to include(depended.id)
      expect(CompactionTraversal.new.entity_ids_for_phase("orphans")).not_to include(depended.id)
      expect(OrphanMatchingStrategy.orphan?(depended)).to be(false)
      expect(OrphanMatchingStrategy.orphan?(used_by_other)).to be(true)
    end
  end

  describe "phase 1" do
    it "queues an add row for a dependency-like orphan instead of parenting it" do
      orphan = MemoryEntity.create!(name: "SynthApp_parser", entity_type: "library")

      run = compact

      expect(MemoryRelation.where(from_entity_id: orphan.id)).not_to exist
      expect(MaintenanceReportRow.where(kind: "orphan_parent")).not_to exist
      row = MaintenanceReportRow.find_by!(kind: "relation_retype")
      expect(row.payload).to include("operation" => "add", "relation_id" => nil, "old_type" => nil, "new_type" => "depends_on",
                                     "from_entity_id" => synth_app.id, "to_entity_id" => orphan.id)
      expect(row.payload["evidence"]).to include("entity_type" => "Framework", "matched_tokens" => include("synthapp"))
      expect(row.payload["evidence"]["score"]).to be >= OrphanMatchingStrategy::AUTO_PARENT_SCORE
      expect(run.stats).to include("dependency_adds_queued" => 1)
      expect(run.stats["orphans_parented"].to_i).to eq(0)

      expect(Current.set(actor: "operator:synth@127.0.0.1") { CompactionReviewService.apply(row.row_uuid) }).to include(success: true)
      compact
      expect(MaintenanceReportRow.where(kind: %w[relation_retype orphan_parent]).count).to eq(1)
      expect(OrphanMatchingStrategy.orphan?(orphan)).to be(false)
    end

    it "doesn't queue a dismissed add row again" do
      MemoryEntity.create!(name: "SynthApp_parser", entity_type: "Gem")
      compact
      CompactionReviewService.dismiss(MaintenanceReportRow.find_by!(kind: "relation_retype").row_uuid, reason: "not a dependency")

      run = compact

      expect(MaintenanceReportRow.where(kind: "relation_retype").count).to eq(1)
      expect(run.stats["dependency_adds_queued"].to_i).to eq(0)
    end

    it "parents another orphan as before, in an undoable compaction.auto_parent change set attributed to the run" do
      orphan = MemoryEntity.create!(name: "SynthApp_task", entity_type: "Task")

      run = compact

      edge = MemoryRelation.find_by!(from_entity_id: orphan.id, to_entity_id: synth_app.id, relation_type: "part_of")
      expect(orphan.reload.project_id).to eq(synth_app.id)
      expect(run.stats["orphans_parented"]).to eq(1)
      set = ChangeSet.find_by!(kind: "compaction.auto_parent")
      expect(set).to have_attributes(actor: "compaction:#{run.id}", undo_strategy: "audit")
      audit = AuditLog.find_by!(auditable_type: "MemoryRelation", auditable_id: edge.id, action: "create")
      expect(audit).to have_attributes(actor: "compaction:#{run.id}", change_set_id: set.id)

      expect(ChangeSetUndo.call(set.uuid, actor: "operator:synth@127.0.0.1")).to be_ok
      expect(MemoryRelation.exists?(edge.id)).to be(false)
      expect(orphan.reload.project_id).to be_nil
    end
  end

  describe "the still_qualifies policy" do
    def orphan_row(orphan)
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "dream_state_compaction", items: [ {
        id: SecureRandom.uuid, kind: "orphan_parent", entity_id: orphan.id, entity_name: orphan.name, entity_type: orphan.entity_type,
        suggested_parents: [ { project_id: synth_app.id, project_name: synth_app.name, score: 10, matched_tokens: %w[synthapp] } ]
      } ]).sole
    end

    it "dismisses an orphan row whose entity a Project now depends_on, or whose type is dependency-like" do
      depended = MemoryEntity.create!(name: "SynthApp_task", entity_type: "Task")
      dependency = MemoryEntity.create!(name: "SynthApp_cli", entity_type: "Tool")
      kept = MemoryEntity.create!(name: "SynthApp_step", entity_type: "Task")
      rows = [ depended, dependency, kept ].map { |orphan| orphan_row(orphan) }
      MemoryRelation.create!(from_entity: synth_app, to_entity: depended, relation_type: "depends_on")

      expect(ReviewPolicies::StillQualifies.new.call["acted"]).to eq(2)
      expect(rows.map { |row| row.reload.status }).to eq(%w[dismissed dismissed active])
    end
  end
end
