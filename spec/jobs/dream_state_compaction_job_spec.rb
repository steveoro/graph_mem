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

  # PR 2 of the part_of membership plan: run.with_lock opens a transaction around the batch, so a
  # batch that can merge takes the membership lock before it.
  describe "membership lock" do
    let(:run) do
      CompactionRun.create!(status: "running", phase: "tree_walk", cursor_entity_id: project.id,
                            stats: { "integrity_sweep_done" => true }, started_at: Time.current)
    end

    before { AppSettings.enable_dream_state_compactor = true }

    it "auto-merges with the lock taken before run.with_lock's transaction", :with_test_embeddings do
      pair = [ fs_member!(project, "SynthWidget", "Task"), fs_member!(project, "SynthWidgetTwin", "Task") ]
      pair.each do |entity|
        MemoryObservation.create!(memory_entity: entity, content: "SynthWidget batches gadget frames before the nightly export run.")
        assign_test_embedding!(entity, 1.0, 0.0)
      end

      expect(open_transactions_at_get_lock { described_class.new.perform(run.id) }).to eq(0)

      expect(MemoryEntity.where(id: pair.map(&:id)).count).to eq(1)
      expect(run.reload.stats["merges_auto"]).to eq(1)
      expect(membership_lock_free?).to be(true)
    end

    it "runs the batch later, without failing the run, while the lock stays busy" do
      fs_member!(project, "SynthWidget", "Task") # the batch's entity, left unprocessed
      stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
      conn = ActiveRecord::Base.connection
      holder = stub_const("DreamStateLockHolder", Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(ProjectMembership.lock_name(conn))}, 5)")

      expect { described_class.new.perform(run.id) }.to have_enqueued_job(described_class).with(run.id)

      expect(run.reload.status).to eq("running")
      expect(run.stats["entities_processed"].to_i).to eq(0)
    ensure
      holder&.connection&.select_value("SELECT RELEASE_LOCK(#{conn.quote(ProjectMembership.lock_name(conn))})")
      holder&.connection_pool&.disconnect!
    end
  end
end
