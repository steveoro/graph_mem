# frozen_string_literal: true

require "rails_helper"

# 1.86.0: a machine that was off at night starts "Run all scheduled jobs now" by itself, once it has
# been up for a while and nothing ran in the last day.
RSpec.describe ScheduledRunCatchUpJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  # The test environment keeps no Solid Queue tables (production has them in its own SQLite queue
  # database): create the one table the job reads, the way db/queue_schema.rb defines it.
  before(:all) do
    ActiveRecord::Base.connection.create_table :solid_queue_processes, if_not_exists: true do |t|
      t.string :kind, null: false
      t.datetime :last_heartbeat_at, null: false
      t.bigint :supervisor_id
      t.integer :pid, null: false
      t.string :hostname
      t.text :metadata
      t.datetime :created_at, null: false
      t.string :name, null: false
    end
  end

  after(:all) { ActiveRecord::Base.connection.drop_table :solid_queue_processes, if_exists: true }

  let(:now) { Time.zone.local(2026, 11, 13, 12, 0, 0) }
  # The nightly compaction slot is 03:00 (in UTC here: the job reads it in Solid Queue's time zone).
  let(:schedule_steps) { [ ScheduledRun::Step.new(entry: "DreamStateCompactionJob", schedule: "at 3am every day") ] }

  before do
    allow(ScheduledRun).to receive(:steps).and_return(schedule_steps)
    allow(SolidQueue).to receive(:time_zone).and_return("UTC")
  end

  around { |example| travel_to(now) { example.run } }

  after do
    OperationProgress.where(operation_type: %w[scheduled_run compaction]).delete_all
    CompactionRun.delete_all
    AppSettings.where(var: "scheduled_run_catch_up_enabled").delete_all
  end

  # A Solid Queue supervisor that has been up for `age` and still beats.
  def supervisor(age: 25.minutes, kind: "Supervisor(fork)", heartbeat: Time.current)
    SolidQueue::Process.create!(kind: kind, name: "supervisor-#{SecureRandom.hex(4)}", pid: rand(2..99_999),
                                last_heartbeat_at: heartbeat, created_at: age.ago)
  end

  def scheduled_run(status: "completed", started: 30.hours.ago)
    OperationProgress.start!(operation_type: "scheduled_run", total_count: 1, details: { "steps" => [], "index" => 0 }).tap do |row|
      row.update!(status: status, started_at: started, finished_at: (started + 1.hour if status == "completed"))
    end
  end

  def compaction_run(started: 30.hours.ago)
    CompactionRun.create!(status: "completed", started_at: started, finished_at: started + 1.hour)
  end

  def current_run = ScheduledRunJob.current

  describe "#perform" do
    before { supervisor }

    it "starts a scheduled run when nothing blocks it, and records the trigger" do
      expect { described_class.perform_now }.to have_enqueued_job(ScheduledRunJob)

      expect(current_run.details["trigger"]).to eq("catch-up")
      expect(ScheduledRunJob.state).to eq(:running)
    end

    it "starts one after an old run and an old compaction" do
      j = described_class.new; begin; Fugit.parse("0 3 * * * UTC").previous_time; rescue => e; puts e.class, e.message, e.backtrace.first(4); end
      scheduled_run(started: 10.hours.ago) # 02:00, before the 03:00 slot
      compaction_run(started: 10.hours.ago)

      expect(described_class.perform_now).to be_a(OperationProgress)
      expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(2)
    end

    it "logs one info line naming the reasons when it starts a run" do
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(/\[ScheduledRunCatchUp\] started .*supervisor up 25 min.*no scheduled run/).once
    end

    it "does nothing when the setting is off" do
      AppSettings.scheduled_run_catch_up_enabled = false
      allow(Rails.logger).to receive(:info)

      expect { described_class.perform_now }.not_to have_enqueued_job(ScheduledRunJob)
      expect(current_run).to be_nil
      expect(Rails.logger).not_to have_received(:info).with(/\[ScheduledRunCatchUp\]/)
    end

    it "is on by default" do
      expect(AppSettings.scheduled_run_catch_up_enabled?).to be(true)
    end

    it "waits for the boot grace period" do
      SolidQueue::Process.delete_all
      supervisor(age: 19.minutes)

      expect(described_class.perform_now).to be_nil
      expect(current_run).to be_nil
    end

    it "starts once the supervisor has been up exactly the grace period" do
      SolidQueue::Process.delete_all
      supervisor(age: ScheduledRunCatchUpJob::BOOT_GRACE)

      expect(described_class.perform_now).to be_a(OperationProgress)
    end

    it "uses the oldest live supervisor, ignoring one that stopped beating" do
      SolidQueue::Process.delete_all
      supervisor(age: 3.days, heartbeat: 1.hour.ago) # a dead one from before the last boot
      supervisor(age: 5.minutes)

      expect(described_class.perform_now).to be_nil
    end

    it "does nothing without a live supervisor" do
      SolidQueue::Process.delete_all

      expect(described_class.perform_now).to be_nil
    end

    it "does not start while a scheduled run is running with a job behind it" do
      row = scheduled_run(status: "running", started: 21.hours.ago)
      allow(ScheduledRunJob).to receive(:live_job?).with(row).and_return(true)

      expect(described_class.perform_now).to be_nil
      expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
    end

    it "leaves a stopping run with a live job alone" do
      row = scheduled_run(status: "running", started: 21.hours.ago)
      row.update!(details: row.details.merge("stop_requested" => true))
      allow(ScheduledRunJob).to receive(:live_job?).and_return(true)

      expect(described_class.perform_now).to be_nil
      expect(row.reload.details["stop_requested"]).to be(true)
    end

    it "never resumes or replaces a paused run" do
      row = scheduled_run(status: "paused", started: 21.hours.ago)
      allow(ScheduledRunJob).to receive(:live_job?).and_return(false)

      expect { expect(described_class.perform_now).to be_nil }.not_to have_enqueued_job(ScheduledRunJob)
      expect(row.reload.status).to eq("paused")
      expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
    end

    describe "a run cut off by a power cut (running, no job left for it)" do
      before { allow(ScheduledRunJob).to receive(:live_job?).and_return(false) }

      def interrupted(stop_requested: false)
        row = ScheduledRunJob.start!(steps: [ ScheduledRun::Step.new(entry: "ChangeSetPruneJob", schedule: "every day"),
                                              ScheduledRun::Step.new(entry: "FactKeywordsJob", schedule: "every day") ])
        row.update!(details: row.details.merge("index" => 1, "stop_requested" => stop_requested), started_at: 1.hour.ago)
        row
      end

      it "is resumed at its stored step, with one info line" do
        row = interrupted
        old_token = row.details["token"]
        allow(Rails.logger).to receive(:info)

        expect { expect(described_class.perform_now).to eq(row) }.to have_enqueued_job(ScheduledRunJob).with(row.operation_id, anything)

        row.reload
        expect(row).to have_attributes(status: "running")
        expect(row.details).to include("index" => 1, "stop_requested" => false)
        expect(row.details["token"]).not_to eq(old_token)
        expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
        expect(Rails.logger).to have_received(:info).with(/\[ScheduledRunCatchUp\] resumed an interrupted run at step 2 of 2/).once
      end

      it "is resumed even though it started within the last day" do
        row = interrupted

        expect(described_class.perform_now).to eq(row)
        expect(row.reload.status).to eq("running")
      end

      it "only finishes the stop of one that was stopping: the operator asked it to stop (Graphy, #173)" do
        row = interrupted(stop_requested: true)

        expect { expect(described_class.perform_now).to be_nil }.not_to have_enqueued_job(ScheduledRunJob)
        expect(row.reload.status).to eq("paused")
        expect(described_class.perform_now).to be_nil
        expect(row.reload.status).to eq("paused")
      end

      it "waits for the boot grace period like any start" do
        interrupted
        SolidQueue::Process.delete_all
        supervisor(age: 5.minutes)

        expect { expect(described_class.perform_now).to be_nil }.not_to have_enqueued_job(ScheduledRunJob)
      end

      it "is left alone when the setting is off" do
        row = interrupted
        AppSettings.scheduled_run_catch_up_enabled = false

        expect(described_class.perform_now).to be_nil
        expect(row.reload.status).to eq("running")
      end
    end

    describe "the last nightly slot (03:00)" do
      # The host's supervisor starts at `time` and has been up 25 minutes when the job looks.
      def boot_at(time)
        travel_to(time)
        SolidQueue::Process.delete_all
        supervisor
      end

      it "does not start when a scheduled run started at or after the slot, whatever its outcome" do
        %w[completed failed].each do |status|
          OperationProgress.where(operation_type: "scheduled_run").delete_all
          scheduled_run(status: status, started: Time.zone.local(2026, 11, 13, 3, 0, 0)) # exactly at the slot

          expect(described_class.perform_now).to be_nil
          expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
        end
      end

      it "does not start when a compaction run started at or after the slot" do
        compaction_run(started: 8.hours.ago) # 04:00

        expect(described_class.perform_now).to be_nil
        expect(current_run).to be_nil
      end

      it "starts when the last runs began just before the slot" do
        scheduled_run(started: Time.zone.local(2026, 11, 13, 2, 59, 0))
        compaction_run(started: Time.zone.local(2026, 11, 13, 2, 59, 0))

        expect(described_class.perform_now).to be_a(OperationProgress)
      end

      it "is overdue on every boot of a host that is off at night: the same time each day, no drift" do
        boot_at(Time.zone.local(2026, 11, 13, 12, 0, 0))
        expect(described_class.perform_now).to be_a(OperationProgress) # catch-up at 12:00
        ScheduledRunJob.current.complete!

        boot_at(Time.zone.local(2026, 11, 14, 2, 50, 0)) # up again before the 03:00 slot: yesterday's run counts
        expect(described_class.perform_now).to be_nil

        boot_at(Time.zone.local(2026, 11, 14, 12, 10, 0)) # the next lunch time: the 03:00 slot was missed
        expect(described_class.perform_now).to be_a(OperationProgress)
        expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(2)
      end

      it "does not run again at night on a host that stayed up: the 03:00 compaction counts" do
        boot_at(Time.zone.local(2026, 11, 13, 12, 0, 0))
        expect(described_class.perform_now).to be_a(OperationProgress)
        ScheduledRunJob.current.complete!

        travel_to(Time.zone.local(2026, 11, 14, 3, 0, 20)) # the nightly compaction ran
        CompactionRun.create!(status: "completed", started_at: Time.current, finished_at: Time.current + 30.minutes)

        [ Time.zone.local(2026, 11, 14, 3, 15, 0), Time.zone.local(2026, 11, 14, 14, 0, 0), Time.zone.local(2026, 11, 14, 23, 30, 0) ].each do |time|
          travel_to(time)
          SolidQueue::Process.update_all(last_heartbeat_at: time)
          expect(described_class.perform_now).to be_nil, "started at #{time}"
        end
        expect(OperationProgress.where(operation_type: "scheduled_run").count).to eq(1)
      end

      it "falls back to 20 hours when no compaction schedule can be read" do
        [ [], [ ScheduledRun::Step.new(entry: "DreamStateCompactionJob", schedule: "no such schedule") ] ].each do |steps|
          allow(ScheduledRun).to receive(:steps).and_return(steps)
          OperationProgress.where(operation_type: "scheduled_run").delete_all
          scheduled_run(started: 19.hours.ago)
          expect(described_class.perform_now).to be_nil

          OperationProgress.where(operation_type: "scheduled_run").delete_all
          scheduled_run(started: 21.hours.ago)
          expect(described_class.perform_now).to be_a(OperationProgress)
          OperationProgress.where(operation_type: "scheduled_run").delete_all
        end
      end
    end

    describe "a compaction run that is not finished" do
      it "doesn't block while paused: the MCP write valve pauses it, and the run's compaction step resumes it (Graphy, #173)" do
        CompactionRun.create!(status: "paused", started_at: 3.days.ago)

        expect(described_class.perform_now).to be_a(OperationProgress)
        expect(current_run).to be_present
      end

      it "blocks while running with a job behind it, however long ago it started" do
        CompactionRun.create!(status: "running", started_at: 3.days.ago)
        allow(ScheduledRunJob).to receive(:compaction_job_live?).and_return(true)

        expect(described_class.perform_now).to be_nil
        expect(current_run).to be_nil
      end

      it "doesn't block when it is running with no job left (a power cut): the run starts it again" do
        CompactionRun.create!(status: "running", started_at: 3.days.ago)
        allow(ScheduledRunJob).to receive(:compaction_job_live?).and_return(false)

        expect(described_class.perform_now).to be_a(OperationProgress)
      end
    end

    it "logs no info line when it skips" do
      scheduled_run(status: "completed", started: 1.hour.ago)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).not_to have_received(:info).with(/\[ScheduledRunCatchUp\]/)
    end
  end

  it "recurs every 15 minutes in production only" do
    schedule = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    entry = schedule.fetch("production").values.find { |config| config["class"] == "ScheduledRunCatchUpJob" }
    expect(entry["schedule"]).to eq("every 15 minutes")
    expect(schedule.fetch("development").values.map { |config| config["class"] }).not_to include("ScheduledRunCatchUpJob")
  end
end
