# frozen_string_literal: true

require "rails_helper"

# 1.81.0: every job of config/recurring.yml once, in a safe order, for the "Run all scheduled jobs
# now" switch on System › Background jobs.
RSpec.describe ScheduledRun do
  let(:path) { Rails.root.join("tmp", "scheduled_run_#{SecureRandom.hex(4)}.yml") }

  after do
    FileUtils.rm_f(path)
    AppSettings.where(var: "enable_garbage_collector").delete_all
  end

  def schedule(env, entries)
    path.write({ env => entries }.to_yaml)
    path
  end

  it "runs each entry once, in ORDER, keeping the first schedule of a repeated one" do
    schedule("production", {
      "review_policy" => { "class" => "ReviewPolicyJob", "schedule" => "at 5:00am every day" },
      "backup_at_13" => { "class" => "DatabaseBackupJob", "schedule" => "every day at 1pm" },
      "garbage_collection" => { "class" => "GarbageCollectionJob", "schedule" => "at 2pm every day" },
      "backup_at_17" => { "class" => "DatabaseBackupJob", "schedule" => "every day at 5pm" }
    })

    steps = described_class.steps(env: "production", path: path)

    expect(steps.map(&:entry)).to eq(%w[DatabaseBackupJob GarbageCollectionJob ReviewPolicyJob])
    expect(steps.first).to have_attributes(schedule: "every day at 1pm", label: "Database backup")
  end

  it "appends an entry missing from ORDER, so a newly scheduled job is never skipped" do
    schedule("production", {
      "synth" => { "class" => "SynthNewJob", "schedule" => "every hour" },
      "cleanup" => { "command" => "ExportJob.cleanup_old_exports", "schedule" => "every hour" },
      "prune" => { "class" => "ChangeSetPruneJob", "schedule" => "at 5:30am every day" }
    })

    steps = described_class.steps(env: "production", path: path)

    expect(steps.map(&:entry)).to eq(%w[ChangeSetPruneJob ExportJob.cleanup_old_exports SynthNewJob])
    expect(steps[1].label).to eq("ExportJob.cleanup_old_exports")
  end

  it "runs a command as a class method, and refuses any other command" do
    expect(ScheduledRun::Step.new(entry: "ExportJob.cleanup_old_exports", schedule: nil).run!).to be_nil.or be_an(Array)
    expect { ScheduledRun::Step.new(entry: "system('true')", schedule: nil).run! }.to raise_error(ArgumentError, /not a Class\.method/)
  end

  it "leaves out the entries this environment doesn't schedule" do
    schedule("development", { "prune" => { "class" => "ChangeSetPruneJob", "schedule" => "at 5:30am every day" } })

    expect(described_class.steps(env: "development", path: path).map(&:entry)).to eq(%w[ChangeSetPruneJob])
    expect(described_class.steps(env: "production", path: path)).to eq([])
  end

  it "reports a step whose own setting is off" do
    schedule("production", { "gc" => { "class" => "GarbageCollectionJob", "schedule" => "at 2pm every day" },
                             "prune" => { "class" => "ChangeSetPruneJob", "schedule" => "at 5:30am every day" } })
    AppSettings.enable_garbage_collector = false

    gc, prune = described_class.steps(env: "production", path: path)

    expect(gc.enabled?).to be(false)
    expect(prune.enabled?).to be(true)
  end

  it "knows the compaction and the stoppable steps" do
    steps = described_class.steps(env: "production").index_by(&:entry)

    expect(steps.values.select(&:compaction?).map(&:entry)).to eq(%w[DreamStateCompactionJob])
    expect(steps.values.select(&:stoppable?).map(&:entry)).to eq(%w[EmbeddingScheduledBackfillJob FactKeywordsJob])
  end

  it "matches the production schedule: place a newly scheduled job in ORDER" do
    expect(described_class.steps(env: "production").map(&:entry)).to eq(described_class::ORDER)
  end
end
