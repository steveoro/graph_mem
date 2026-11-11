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

  def run(row) = described_class.perform_now(row.operation_id)

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
    expect(described_class).to have_been_enqueued.with(row.operation_id)
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

    expect(described_class.stop!(row, live: true)).to be(true)
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

    expect(described_class.stop!(row)).to be(true)
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

  it "is idle with no run, or after one finished" do
    expect(described_class.state).to eq(:idle)
    row = described_class.start!(steps: steps("SynthAlphaJob"))
    expect(described_class.state).to eq(:running)
    run(row)
    expect(described_class.state).to eq(:idle)
  end
end
