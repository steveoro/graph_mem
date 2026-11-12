# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceDashboardSnapshot do
  after { CompactionRun.delete_all; MaintenanceReport.delete_all; OperationProgress.delete_all }

  describe ".call" do
    it "returns what Background jobs shows: compaction, graph stats, reports, schedules, the last GC run" do
      MemoryEntity.create!(name: "SnapEntity", entity_type: "Project")

      result = described_class.call

      expect(result.keys).to contain_exactly(:refreshed_at, :compaction, :graph_stats, :latest_reports, :schedules, :cursor_entity, :operations,
                                             :scheduled_run, :active)
      expect(result[:active]).to be(false)
      expect(described_class.cards.keys).to eq(result.keys - [ :graph_stats ])
      expect(result[:scheduled_run]).to include(state: :idle, run: nil, latest_audit: nil)
      expect(result[:graph_stats][:totals][:entities]).to be >= 1
      expect(result[:compaction]).to include(:dream_state)
      expect(result[:operations].keys).to eq([ :garbage_collection ])
    end

    it "resolves cursor entity when compaction has a cursor" do
      entity = MemoryEntity.create!(name: "CursorNode", entity_type: "Task")
      CompactionRun.create!(
        status: "running",
        phase: "orphans",
        cursor_entity_id: entity.id,
        stats: { "entities_processed" => 0, "merges_auto" => 0, "merges_queued" => 0,
                 "observations_deduped" => 0, "orphans_parented" => 0, "orphans_queued" => 0 }
      )

      result = described_class.call

      expect(result[:cursor_entity]).to eq(
        id: entity.id,
        name: "CursorNode",
        entity_type: "Task"
      )
    end

    it "includes latest maintenance reports by type" do
      MaintenanceReport.create!(report_type: "orphans", data: { count: 2, entities: [] })

      result = described_class.call

      expect(result[:latest_reports]["orphans"][:count]).to eq(2)
    end
  end

  # 1.84.0: how far the scheduled run's current step is, for the bar under its label.
  describe "scheduled_run step_progress" do
    def run_at(entry, step = {})
      details = { "index" => 0, "stop_requested" => false, "token" => "t",
                  "steps" => [ { "entry" => entry, "label" => entry, "outcome" => "running", "started_at" => 1.minute.ago.iso8601 }.merge(step) ] }
      OperationProgress.start!(operation_type: ScheduledRunJob::OPERATION_TYPE, total_count: 1, details: details)
    end

    def step_progress = described_class.new.scheduled_run_snapshot[:step_progress]

    it "is nil with no run, and for a step that reports nothing (an indeterminate bar)" do
      expect(step_progress).to be_nil
      run_at("DatabaseBackupJob")
      expect(step_progress).to be_nil
    end

    it "comes from what the step reported" do
      run_at("FactKeywordsJob", "progress" => { "done" => 40, "total" => 160, "label" => "LLM words" })

      expect(step_progress).to eq(percent: 25, done: 40, total: 160, label: "LLM words")
    end

    it "is nil once the step is over, and when it reported nothing to do" do
      row = run_at("FactKeywordsJob", "progress" => { "done" => 0, "total" => 0, "label" => "LLM words" })
      expect(step_progress).to be_nil

      row.update!(status: "paused")
      expect(step_progress).to be_nil
    end

    it "comes from the compaction run's own progress row while the step waits on it" do
      op = OperationProgress.start!(operation_type: "compaction", total_count: 10, phase: "merges")
      op.update_progress!(current: 3)
      compaction = CompactionRun.create!(status: "running", operation_progress: op, stats: {})
      run_at("DreamStateCompactionJob", "outcome" => "waiting", "compaction_run_id" => compaction.id)

      expect(step_progress).to eq(percent: 30, done: 3, total: 10, label: "merges")
    end

    it "comes from the garbage collection's progress row started during the step, not an older one" do
      old = OperationProgress.start!(operation_type: "garbage_collection", total_count: 4, phase: "old")
      old.update_columns(created_at: 1.hour.ago)
      run_at("GarbageCollectionJob")
      expect(step_progress).to be_nil

      gc = OperationProgress.start!(operation_type: "garbage_collection", total_count: 4, phase: "duplicates")
      gc.update_progress!(current: 1)
      expect(step_progress).to eq(percent: 25, done: 1, total: 4, label: "duplicates")
    end
  end
end
