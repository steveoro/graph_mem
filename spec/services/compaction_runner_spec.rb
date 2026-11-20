# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionRunner, type: :service do
  include ActiveJob::TestHelper

  after { CompactionRun.delete_all }

  describe ".acquire_run!" do
    it "creates a new run when none is active" do
      run = described_class.acquire_run!

      expect(run).to be_running
      expect(run.phase).to eq("relation_types")
      expect(run.stats).to include("entities_processed" => 0, "relations_processed" => 0)
    end

    it "counts the relations once and the entities once per entity phase in the progress total" do
      a = MemoryEntity.create!(name: "SynthService #{SecureRandom.hex(3)}", entity_type: "Service")
      b = MemoryEntity.create!(name: "SynthWidget #{SecureRandom.hex(3)}", entity_type: "Component")
      MemoryRelation.create!(from_entity: a, to_entity: b, relation_type: "depends_on")

      run = described_class.acquire_run!

      expect(run.stats).to include("total_entities" => 2, "total_relations" => 1)
      expect(run.operation_progress.total_count).to eq((2 * CompactionRun::ENTITY_PHASES.size) + 1)
    end

    it "resumes a paused run instead of creating a duplicate" do
      paused = CompactionRun.create!(status: "paused", phase: "tree_walk", stats: {})

      run = described_class.acquire_run!

      expect(run.id).to eq(paused.id)
      expect(run.reload).to be_running
      expect(CompactionRun.count).to eq(1)
    end

    it "returns the existing running run" do
      existing = CompactionRun.create!(status: "running", phase: "orphans", stats: {})

      expect(described_class.acquire_run!.id).to eq(existing.id)
    end

    it "resumes a failed run instead of creating a new one" do
      failed = CompactionRun.create!(
        status: "failed",
        phase: "tree_walk",
        cursor_entity_id: 99,
        stats: { "entities_processed" => 12, "error" => "boom" },
        started_at: 1.hour.ago,
        finished_at: 30.minutes.ago
      )

      run = described_class.acquire_run!

      expect(run.id).to eq(failed.id)
      expect(run.reload).to be_running
      expect(run.phase).to eq("tree_walk")
      expect(run.cursor_entity_id).to eq(99)
      expect(run.stats).not_to have_key("error")
      expect(CompactionRun.count).to eq(1)
    end
  end

  describe ".start_or_resume!" do
    it "enqueues a compaction job" do
      expect {
        described_class.start_or_resume!
      }.to have_enqueued_job(DreamStateCompactionJob)
    end
  end

  describe ".status_snapshot" do
    it "returns idle when no runs exist" do
      expect(described_class.status_snapshot).to eq(dream_state: "idle")
    end

    it "returns the active run details" do
      run = CompactionRun.create!(
        status: "paused",
        phase: "orphans",
        cursor_entity_id: 42,
        stats: { "entities_processed" => 3 },
        started_at: Time.current
      )

      snapshot = described_class.status_snapshot

      expect(snapshot[:dream_state]).to eq("paused")
      expect(snapshot[:run_id]).to eq(run.id)
      expect(snapshot[:cursor_entity_id]).to eq(42)
      expect(snapshot[:stats]["entities_processed"]).to eq(3)
    end

    it "uses a fixed overall denominator and caps completion at 100%" do
      CompactionRun.create!(
        status: "completed",
        phase: "relationship_discovery",
        stats: { "entities_processed" => 12, "total_entities" => 10 },
        started_at: Time.current,
        finished_at: Time.current
      )

      snapshot = described_class.status_snapshot

      expect(snapshot[:progress][:overall][:total]).to eq(10 * CompactionRun::ENTITY_PHASES.size)
      expect(snapshot[:progress][:overall][:percent]).to eq(100)
    end

    it "adds the relations the relation_types phase walked to the fallback progress" do
      CompactionRun.create!(status: "paused", phase: "orphans",
                            stats: { "entities_processed" => 2, "relations_processed" => 5, "total_entities" => 10, "total_relations" => 5 })

      progress = described_class.status_snapshot[:progress][:overall]

      expect(progress).to include(current: 7, total: (10 * CompactionRun::ENTITY_PHASES.size) + 5)
    end
  end
end
