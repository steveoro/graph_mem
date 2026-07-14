# frozen_string_literal: true

require "rails_helper"

RSpec.describe DreamStateCompactionJob, type: :job do
  include ActiveJob::TestHelper

  after { CompactionRun.delete_all }

  let!(:project) { MemoryEntity.create!(name: "JobProject", entity_type: "Project") }

  describe "job queueing" do
    it "queues on the default queue" do
      expect {
        described_class.perform_later
      }.to have_enqueued_job(described_class).on_queue("default")
    end
  end

  describe "#perform" do
    it "skips when dream-state compactor is disabled" do
      AppSettings.enable_dream_state_compactor = false

      expect(CompactionRunner).not_to receive(:acquire_run!)
      described_class.new.perform
    end

    it "acquires a run when no run_id is provided" do
      expect(CompactionRunner).to receive(:acquire_run!).and_call_original

      described_class.new.perform
    end

    it "re-enqueues itself while work remains" do
      run = CompactionRun.create!(
        status: "running",
        phase: "tree_walk",
        stats: {},
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_return(:continued)

      expect {
        described_class.new.perform(run.id)
      }.to have_enqueued_job(described_class).with(run.id)
    end

    it "does not re-enqueue when paused" do
      run = CompactionRun.create!(
        status: "running",
        phase: "tree_walk",
        stats: {},
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_return(:paused)

      expect {
        described_class.new.perform(run.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "marks failed runs on unexpected errors" do
      run = CompactionRun.create!(
        status: "running",
        phase: "orphans",
        stats: {},
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_raise(StandardError, "boom")

      expect {
        described_class.new.perform(run.id)
      }.to raise_error(StandardError, "boom")

      expect(run.reload.status).to eq("failed")
      expect(run.stats["error"]).to eq("boom")
    end

    it "runs a pre-flight integrity sweep for a brand-new run" do
      CompactionRun.create!(
        status: "running",
        phase: "tree_walk",
        stats: {},
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_return(:completed)
      expect(GraphIntegrityService).to receive(:call)

      described_class.new.perform
    end

    it "skips the pre-flight sweep when resuming a run" do
      CompactionRun.create!(
        status: "running",
        phase: "tree_walk",
        cursor_entity_id: project.id,
        stats: { "entities_processed" => 5 },
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_return(:completed)
      expect(GraphIntegrityService).not_to receive(:call)

      described_class.new.perform
    end

    it "logs and continues when the pre-flight sweep raises" do
      CompactionRun.create!(
        status: "running",
        phase: "tree_walk",
        stats: {},
        started_at: Time.current
      )

      allow_any_instance_of(DreamStateCompactor).to receive(:process_batch!).and_return(:completed)
      allow(GraphIntegrityService).to receive(:call).and_raise(StandardError, "sweep failed")

      expect(Rails.logger).to receive(:error).with(/Pre-flight integrity sweep failed/)

      described_class.new.perform
    end
  end
end
