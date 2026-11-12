# frozen_string_literal: true

require "rails_helper"

# 1.81.0: "Run all scheduled jobs now" runs the steps one at a time, waits on compaction, and stops
# and resumes on the same switch.
RSpec.describe ScheduledRunJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:calls) { [] }

  before do
    log = calls
    stub_const("SynthAlphaJob", Class.new(ApplicationJob) { define_method(:perform) { log << :alpha } })
    stub_const("SynthBetaJob", Class.new(ApplicationJob) { define_method(:perform) { log << :beta } })
    stub_const("SynthGammaJob", Class.new(ApplicationJob) { define_method(:perform) { log << :gamma } })
    stub_const("SynthBoomJob", Class.new(ApplicationJob) { define_method(:perform) { raise "boom" } })
  end

  after do
    CompactionRun.delete_all
    AppSettings.where(var: "enable_garbage_collector").delete_all
  end

  def steps(*entries) = entries.map { |entry| ScheduledRun::Step.new(entry: entry, schedule: "every day at 1pm") }

  def outcomes(row) = row.reload.details["steps"].map { |step| step["outcome"] }

  def run(row) = described_class.perform_now(row.operation_id, row.reload.details["token"])

  it "runs every step in order and completes" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob", "SynthGammaJob"))
    run(row)

    expect(calls).to eq(%i[alpha beta gamma])
    expect(outcomes(row)).to eq(%w[done done done])
    expect(row).to have_attributes(status: "completed", current_count: 3, total_count: 3)
  end

  it "records a failing step and goes on" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBoomJob", "SynthGammaJob"))
    run(row)

    expect(outcomes(row)).to eq(%w[done failed done])
    expect(row.details["steps"][1]["error"]).to eq("RuntimeError: boom")
    expect(row.status).to eq("completed")
  end

  it "skips a step whose own setting is off" do
    AppSettings.enable_garbage_collector = false
    row = described_class.start!(steps: steps("GarbageCollectionJob", "SynthAlphaJob"))
    run(row)

    expect(outcomes(row)).to eq(%w[skipped done])
  end

  it "waits on compaction until its run ends, then goes on" do
    row = described_class.start!(steps: steps("DreamStateCompactionJob", "SynthAlphaJob"))
    clear_enqueued_jobs

    run(row)
    expect(outcomes(row)).to eq([ "waiting", nil ])
    expect(described_class).to have_been_enqueued.with(row.operation_id, row.reload.details["token"])
    expect(calls).to be_empty

    CompactionRun.find(row.details["steps"][0]["compaction_run_id"]).mark_completed!
    run(row)

    expect(outcomes(row)).to eq(%w[done done])
    expect(row.details["steps"][0]["note"]).to eq("completed")
    expect(calls).to eq(%i[alpha])
  end

  it "fails the compaction step when its run vanished" do
    row = described_class.start!(steps: steps("DreamStateCompactionJob", "SynthAlphaJob"))
    run(row)
    CompactionRun.delete_all
    run(row)

    expect(outcomes(row)).to eq(%w[failed done])
  end

  it "refuses to start while a run is running or paused" do
    row = described_class.start!(steps: steps("SynthAlphaJob"))

    expect(described_class.start!(steps: steps("SynthAlphaJob"))).to be_nil
    row.pause!
    expect(described_class.start!(steps: steps("SynthAlphaJob"))).to be_nil
    expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
  end

  it "stops after a plain step: it finishes, and the run pauses before the next one" do
    stub_const("SynthStopperJob", Class.new(ApplicationJob) do
      define_method(:perform) { ScheduledRunJob.stop!(ScheduledRunJob.current, live: true) }
    end)
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthStopperJob", "SynthBetaJob"))
    run(row)

    expect(outcomes(row)).to eq([ "done", "done", nil ])
    expect(row).to have_attributes(status: "paused")
    expect(row.details).to include("index" => 2, "stop_requested" => false)
    expect(described_class.state(row)).to eq(:paused)
  end

  it "stops a stoppable step between batches, and resumes it" do
    stub_const("ScheduledRun::STOPPABLE", %w[SynthLoopJob])
    stub_const("CooperativeStop::INTERVAL", 0.seconds)
    log = calls
    stop_once = [ true ]
    stub_const("SynthLoopJob", Class.new(ApplicationJob) do
      define_method(:perform) do
        5.times do |batch|
          break if CooperativeStop.requested?

          log << :"batch#{batch}"
          ScheduledRunJob.stop!(ScheduledRunJob.current, live: true) if batch == 1 && stop_once.shift
        end
      end
    end)
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthLoopJob", "SynthBetaJob"))
    run(row)

    expect(calls).to eq(%i[alpha batch0 batch1])
    # On Resume the loop runs again from its pending work (here, from the start).
    expect(outcomes(row)).to eq([ "done", "stopped", nil ])
    expect(row.reload).to have_attributes(status: "paused")

    expect(described_class.resume!(row)).to be(true)
    run(row)

    expect(outcomes(row)).to eq(%w[done done done])
    expect(row.status).to eq("completed")
  end

  it "stops compaction through its own pause" do
    row = described_class.start!(steps: steps("DreamStateCompactionJob", "SynthAlphaJob"))
    run(row)
    compaction = CompactionRun.find(row.reload.details["steps"][0]["compaction_run_id"])

    expect(described_class.stop!(row, live: true)).to eq(:requested)
    expect(compaction.reload.pause_requested).to be(true)
    expect(described_class.state(row.reload)).to eq(:stopping)

    compaction.pause!
    run(row)

    expect(outcomes(row)).to eq([ "stopped", nil ])
    expect(row.status).to eq("paused")

    described_class.resume!(row)
    run(row)
    expect(compaction.reload.status).to eq("running")
    expect(outcomes(row)).to eq([ "waiting", nil ])
  end

  it "start over abandons the paused run and starts a new one" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob"))
    row.pause!

    fresh = described_class.start_over!(row, steps: steps("SynthAlphaJob"))

    expect(row.reload).to have_attributes(status: "failed", message: "abandoned")
    expect(fresh).to have_attributes(status: "running", total_count: 1)
  end

  it "pauses at once on Stop when no job is left to run the steps" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob"))

    expect(described_class.stop!(row)).to eq(:paused)
    expect(row.reload.status).to eq("paused")
    expect(described_class.state(row)).to eq(:paused)
  end

  it "resumes at the stored index, running the interrupted step again" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob", "SynthGammaJob"))
    details = row.details.deep_dup
    details["index"] = 1
    details["steps"][0]["outcome"] = "done"
    details["steps"][1]["outcome"] = "running"
    row.update!(details: details)

    run(row)

    expect(calls).to eq(%i[beta gamma])
    expect(outcomes(row)).to eq(%w[done done done])
  end

  it "does nothing for a run that isn't running" do
    row = described_class.start!(steps: steps("SynthAlphaJob"))
    row.pause!

    run(row)

    expect(calls).to be_empty
  end

  # Final review fixes.
  it "pauses the run, keeping its step, when the job fails outside a step (an interruption)" do
    stub_const("ScheduledRun::SETTINGS", { "SynthBetaJob" => :no_such_setting? })
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob"))

    expect { run(row) }.to raise_error(NoMethodError)

    expect(row.reload).to have_attributes(status: "paused")
    expect(row.message).to start_with("Interrupted: NoMethodError")
    expect(row.details["index"]).to eq(1)
  end

  it "sees a stop the query cache would hide" do
    row = described_class.start!(steps: steps("SynthAlphaJob"))
    job = described_class.new
    job.instance_variable_set(:@row, row)

    ActiveRecord::Base.cache do
      expect(job.send(:stop_requested?)).to be(false)
      # A write the query cache doesn't see (another process, in production).
      details = row.details.merge("stop_requested" => true).to_json
      OperationProgress.connection.raw_connection.query(
        "UPDATE operation_progresses SET details = #{OperationProgress.connection.quote(details)} WHERE id = #{row.id}"
      )
      expect(job.send(:stop_requested?)).to be(true)
    end
  end

  it "never overwrites the job's progress from a stale copy of the row" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob", "SynthGammaJob"))
    stale = OperationProgress.find(row.id)
    fresh = OperationProgress.find(row.id)
    fresh.update!(details: fresh.details.merge("index" => 2))

    described_class.stop!(stale, live: true)

    expect(row.reload.details).to include("index" => 2, "stop_requested" => true)
  end

  it "ignores a job from an earlier start or resume of the run (a retried old job)" do
    row = described_class.start!(steps: steps("SynthAlphaJob", "SynthBetaJob"))
    old_token = row.reload.details["token"]
    row.pause!
    described_class.resume!(row)

    described_class.perform_now(row.operation_id, old_token)

    expect(calls).to be_empty
    expect(row.reload.details["token"]).not_to eq(old_token)
  end

  # Graphy round 1: a compaction run left running with nothing behind it (a shutdown mid-batch, a
  # discarded job). The test adapter has no Solid Queue, so the check is stubbed: no job.
  context "when nothing is running the compaction run" do
    before { allow(described_class).to receive(:compaction_job_live?).and_return(false) }

    it "starts it again after two empty polls" do
      row = described_class.start!(steps: steps("DreamStateCompactionJob", "SynthAlphaJob"))
      run(row)
      clear_enqueued_jobs

      run(row)
      expect(DreamStateCompactionJob).not_to have_been_enqueued
      run(row)
      expect(DreamStateCompactionJob).to have_been_enqueued
      expect(outcomes(row)).to eq([ "waiting", nil ])
    end

    it "pauses it itself on Stop, and the run pauses" do
      row = described_class.start!(steps: steps("DreamStateCompactionJob", "SynthAlphaJob"))
      run(row)
      compaction = CompactionRun.find(row.reload.details["steps"][0]["compaction_run_id"])
      described_class.stop!(row, live: true)

      2.times { run(row) }

      expect(compaction.reload.status).to eq("paused")
      expect(outcomes(row)).to eq([ "stopped", nil ])
      expect(row.status).to eq("paused")
    end
  end

  it "stops at its next write when the run moved on without it (paused or resumed meanwhile)" do
    log = calls
    stub_const("SynthHijackJob", Class.new(ApplicationJob) do
      define_method(:perform) do
        log << :hijack
        current = ScheduledRunJob.current
        current.update!(details: current.details.merge("token" => "another"))
      end
    end)
    row = described_class.start!(steps: steps("SynthHijackJob", "SynthAlphaJob"))

    expect { run(row) }.not_to raise_error

    expect(calls).to eq(%i[hijack])
    expect(row.reload.status).to eq("running")
  end

  it "never pauses the run that replaced it when it fails afterwards" do
    row = described_class.start!(steps: steps("SynthAlphaJob"))
    old_token = row.details["token"]
    row.update!(details: row.details.merge("token" => "another")) # resumed by another job meanwhile

    described_class.pause!(row, message: "Interrupted", token: old_token)

    expect(row.reload.status).to eq("running")
  end

  it "is idle with no run, or after one finished" do
    expect(described_class.state).to eq(:idle)
    row = described_class.start!(steps: steps("SynthAlphaJob"))
    expect(described_class.state).to eq(:running)
    run(row)
    expect(described_class.state).to eq(:idle)
  end
end
