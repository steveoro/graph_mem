# frozen_string_literal: true

require "rails_helper"

RSpec.describe "System › Background jobs", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before { sign_in_operator }

  after { CompactionRun.delete_all; MaintenanceReport.delete_all }

  it "shows the cards and links to the queue (Mission Control)" do
    get system_jobs_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="background-jobs"', 'data-testid="jobs-queue-link"', 'href="/system/queue"')
  end

  # From the removed maintenance_hub_spec (these pages outlived the hub).
  it "keeps the compactor and garbage collector controls" do
    get system_jobs_path

    jobs = Nokogiri::HTML(response.body).at_css("#background-jobs")
    expect(jobs.text).to include("Dream State / Compactor Run", "Garbage Collector")
    expect(jobs.at_css("#btn-dream-state-resume")).to be_present
    expect(jobs.at_css("#btn-gc-run")).to be_present
    expect(jobs.at_css("#btn-compaction-review")["href"]).to eq(review_path)
    expect(jobs.at_css("#btn-dream-state-refresh")).to be_nil # 1.84.0: the cards refresh themselves
  end

  it "shows the repair action only when compaction failed with a relation error" do
    get system_jobs_path
    expect(response.body).not_to include('id="btn-repair-relations"')

    CompactionRun.create!(
      status: "failed", phase: "tree_walk", started_at: 1.hour.ago, finished_at: 30.minutes.ago,
      stats: { "error" => "Duplicate entry '266-211-part_of' for key 'index_memory_relations_uniqueness'", "entities_processed" => 40 }
    )

    get system_jobs_path
    expect(response.body).to include('id="btn-repair-relations"', "Repair relation duplicates")
  end

  # 1.84.0: the page polls its cards (live_refresh_controller.js) and morphs them in.
  describe "the live cards" do
    after { OperationProgress.where(operation_type: "scheduled_run").delete_all }

    def frame
      html = Nokogiri::HTML(response.body)
      html.at_css("#jobs-cards") || html.at_css("turbo-stream template")
    end

    it "renders the cards inline, in a container that polls the cards endpoint" do
      get system_jobs_path

      expect(frame.attributes.transform_values(&:value))
        .to include("data-controller" => "live-refresh", "data-live-refresh-url-value" => system_jobs_cards_path)
      expect(frame.at_css("[data-testid='scheduled-run-card']")).to be_present
      expect(frame.at_css("#btn-gc-run")).to be_present
    end

    it "serves the cards alone, as a Turbo Stream that morphs the container" do
      get system_jobs_cards_path, headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      stream = Nokogiri::HTML(response.body).at_css("turbo-stream")
      expect(stream.attributes.transform_values(&:value)).to include("action" => "update", "target" => "jobs-cards", "method" => "morph")
      expect(frame.inner_html).to include('data-testid="scheduled-run-card"')
      expect(response.body).not_to include('data-testid="background-jobs-totals"')
    end

    it "flags the cards active while a scheduled run runs, so the page polls faster" do
      get system_jobs_cards_path
      expect(frame.at_css("[data-live-refresh-target='state']")["data-active"]).to eq("false")

      ScheduledRunJob.start!(steps: [ ScheduledRun::Step.new(entry: "ChangeSetPruneJob", schedule: "every day") ])
      get system_jobs_cards_path
      expect(frame.at_css("[data-live-refresh-target='state']")["data-active"]).to eq("true")
    end

    it "never counts a poll as activity, and still expires an idle session" do
      get system_jobs_path
      seen = session[:last_seen_at]

      travel 10.minutes do
        get system_jobs_cards_path
        expect(response).to have_http_status(:ok)
        expect(session[:last_seen_at]).to eq(seen)
      end

      travel SessionAuthentication::OPERATOR_IDLE_TIMEOUT + 1.minute do
        get system_jobs_cards_path
        expect(response).to redirect_to(operator_login_path)
      end
    end

    it "needs the operator, and a signed-out poll isn't where sign-in returns to (final review)" do
      reset!
      get system_jobs_cards_path, headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to redirect_to(operator_login_path)
      expect(session[:operator_return_to]).to be_nil
    end
  end

  # 1.81.0: one switch runs every scheduled job now (start / stop / resume / start over).
  describe "the scheduled-jobs switch" do
    def card = Nokogiri::HTML(response.body).at_css("[data-testid='scheduled-run-card']")

    def button(expected) = card.at_css("form[action='#{system_scheduled_run_path}'] input[name='expected'][value='#{expected}']")&.ancestors("form")&.first

    def press(expected) = post(system_scheduled_run_path, params: { expected: expected })

    def steps(*entries) = entries.map { |entry| ScheduledRun::Step.new(entry: entry, schedule: "every day at 1pm") }

    after { OperationProgress.where(operation_type: "scheduled_run").delete_all }

    it "lists every scheduled step and offers to run them, with a confirmation" do
      # The test environment schedules nothing: the production list, read from the real file.
      allow(ScheduledRun).to receive(:steps).and_return(ScheduledRun.steps(env: "production"))

      get system_jobs_path

      expect(card.css("[data-testid='scheduled-run-step']").map { |li| li.text.squish })
        .to eq(ScheduledRun.steps(env: "production").map { |step| "#{step.label} #{step.schedule}".squish })
      expect(card.css("[data-testid='scheduled-run-step']").size).to eq(ScheduledRun::ORDER.size)
      start = button("start")
      expect(start.at_css("button").text.squish).to eq("Run all scheduled jobs now")
      expect(start.at_css("button")["data-turbo-confirm"]).to be_present
    end

    describe "who started the run" do
      def trigger_note = card.at_css("[data-testid='scheduled-run-trigger']")

      it "says so for a run the catch-up job started, running or finished" do
        row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"), trigger: "catch-up")
        get system_jobs_path
        expect(trigger_note.text.squish).to eq("Started automatically (catch-up)")

        row.update!(status: "completed", finished_at: Time.current)
        get system_jobs_path
        expect(trigger_note.text.squish).to eq("Started automatically (catch-up)")
      end

      it "says nothing for a run started from the button" do
        press("start")
        expect(ScheduledRunJob.current.details["trigger"]).to eq("manual")

        get system_jobs_path
        expect(trigger_note).to be_nil
      end

      it "says nothing for a run from before the trigger was recorded" do
        row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
        row.update!(details: row.details.except("trigger"))

        get system_jobs_path
        expect(trigger_note).to be_nil
      end
    end

    it "starts a run" do
      expect { press("start") }.to have_enqueued_job(ScheduledRunJob)

      expect(response).to redirect_to(system_jobs_path)
      expect(OperationProgress.where(operation_type: "scheduled_run", status: "running").count).to eq(1)
      follow_redirect!
      expect(response.body).to include("Scheduled jobs started")
    end

    it "shows Stop, the current step and its times while running" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob", "MaintenanceReportRowCleanupJob", "ExportJob.cleanup_old_exports"))
      details = row.details.deep_dup
      details["index"] = 1
      details["steps"][0].merge!("outcome" => "done", "started_at" => 3.minutes.ago.iso8601, "finished_at" => 2.minutes.ago.iso8601)
      details["steps"][1].merge!("outcome" => "running", "started_at" => 2.minutes.ago.iso8601)
      row.update_progress!(current: 1, phase: "Maintenance report row cleanup", details: details)
      allow(ScheduledRunJob).to receive(:live_job?).and_return(true) # the test queue has no Solid Queue jobs

      get system_jobs_path

      status = card.at_css("[data-testid='scheduled-run-status']").text.squish
      expect(status).to include("Step 2 of 3", "Maintenance report row cleanup", "Run started", "Step started", "Last progress")
      expect(button("stop").at_css("button").text.squish).to eq("Stop")
      expect(card.css("[data-testid='scheduled-run-step']").map { |li| li.at_css("[data-progress-step-outcome]")&.text.to_s.squish })
        .to eq([ "done", "running", "" ])
    end

    it "shows Stopping… (disabled) once a stop is requested" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
      ScheduledRunJob.stop!(row, live: true)
      allow(ScheduledRunJob).to receive(:live_job?).and_return(true) # the job is still running

      get system_jobs_path

      stopping = card.css("button").find { |node| node.text.squish == "Stopping…" }
      expect(stopping["disabled"]).to be_present
    end

    it "offers Pause now when no job is running the run (a shutdown), even while stopping, and pauses it" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
      ScheduledRunJob.stop!(row, live: true) # Stopping…, then the machine went off

      get system_jobs_path
      expect(card.at_css("[data-testid='scheduled-run-status']").text.squish).to include("No job is running this run")
      expect(button("stop").at_css("button").text.squish).to eq("Pause now")

      press("stop")

      expect(row.reload.status).to eq("paused")
      follow_redirect!
      expect(response.body).to include("Paused: no job was running it")
    end

    it "offers Resume and Start over when paused, and resumes" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
      row.pause!

      get system_jobs_path
      expect(button("resume").at_css("button").text.squish).to eq("Resume")
      expect(button("start_over").at_css("button").text.squish).to eq("Start over")

      expect { press("resume") }.to have_enqueued_job(ScheduledRunJob).with(row.operation_id, anything)
      expect(row.reload.status).to eq("running")
    end

    it "ignores a press made for another state (a stale tab)" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
      row.pause!

      press("stop")

      expect(row.reload.status).to eq("paused")
      follow_redirect!
      expect(response.body).to include("The scheduled run changed meanwhile")
    end

    it "shows the newest audit-log entry since the run started" do
      row = ScheduledRunJob.start!(steps: steps("ChangeSetPruneJob"))
      entity = MemoryEntity.create!(name: "SynthAudited", entity_type: "Component")
      AuditLog.create!(auditable: entity, action: "update", actor: "policy:synth", created_at: 1.second.from_now)

      get system_jobs_path

      expect(card.at_css("[data-testid='scheduled-run-audit']").text.squish)
        .to include("update", "MemoryEntity ##{entity.id}", "policy:synth")
      row.update!(started_at: 1.minute.from_now)
      get system_jobs_path
      expect(card.at_css("[data-testid='scheduled-run-audit']").text.squish).to include("No graph changes logged")
    end

    it "answers a guest with 403" do
      enable_guest!
      sign_in_guest

      press("start")

      expect(response).to have_http_status(:forbidden)
      expect(OperationProgress.where(operation_type: "scheduled_run")).to be_empty
    end
  end

  describe "POST /system/jobs/compaction/start" do
    it "redirects when dream-state compactor is disabled" do
      AppSettings.enable_dream_state_compactor = false

      post system_start_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "starts compaction and redirects with notice" do
      expect {
        post system_start_compaction_path
      }.to have_enqueued_job(DreamStateCompactionJob)

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Dream-state compaction started")
    end
  end

  describe "POST /system/jobs/compaction/pause" do
    it "requests pause on a running compaction" do
      run = CompactionRun.create!(status: "running", phase: "orphans", stats: { "entities_processed" => 0 })

      post system_pause_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      expect(run.reload.pause_requested).to be true
    end

    it "alerts when no running compaction exists" do
      post system_pause_compaction_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("No running compaction")
    end
  end

  describe "POST /system/jobs/garbage_collection/run" do
    it "redirects when garbage collector is disabled" do
      AppSettings.enable_garbage_collector = false

      post system_run_garbage_collection_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("disabled")
    end

    it "runs garbage collection and redirects with report summary" do
      MemoryEntity.create!(name: "OpGC", entity_type: "Project")

      post system_run_garbage_collection_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Garbage collection completed")
      expect(MaintenanceReport.count).to eq(2)
    end
  end

  describe "POST /system/jobs/relations/repair" do
    it "repairs relations and redirects with summary" do
      entity_a = MemoryEntity.create!(name: "OpRepair A", entity_type: "Project")
      entity_b = MemoryEntity.create!(name: "OpRepair B", entity_type: "Task")
      MemoryRelation.create!(from_entity: entity_a, to_entity: entity_b, relation_type: "relates_to")
      MemoryRelation.create!(from_entity: entity_b, to_entity: entity_a, relation_type: "relates_to")

      post system_repair_relations_path

      expect(response).to redirect_to(system_jobs_path)
      follow_redirect!
      expect(response.body).to include("Relation repair completed")
      expect(MemoryRelation.count).to eq(1)
    end
  end

  # 1.84.0: one bar under the running step's label, for how far that step is.
  describe "the step progress bar" do
    after { OperationProgress.where(operation_type: "scheduled_run").delete_all }

    def bar = Nokogiri::HTML(response.body).at_css("[data-testid='scheduled-run-step-progress'] progress")

    def start_run
      ScheduledRunJob.start!(steps: [ ScheduledRun::Step.new(entry: "FactKeywordsJob", schedule: "every day") ]).tap do |row|
        details = row.details.deep_dup
        details["steps"][0].merge!("outcome" => "running", "started_at" => Time.current.iso8601)
        row.update!(details: details)
      end
    end

    it "is indeterminate for a step that reports nothing, and counts what a step reports" do
      row = start_run
      get system_jobs_path
      expect(bar.name).to eq("progress")
      expect(bar["value"]).to be_nil
      expect(bar.key?("data-progress-step")).to be(true)

      details = row.details.deep_dup
      details["steps"][0]["progress"] = { "done" => 1_200, "total" => 3_533, "label" => "LLM words" }
      row.update!(details: details)
      get system_jobs_path

      expect(bar["value"]).to eq("33")
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='scheduled-run-step-progress-label']").text.squish)
        .to eq("LLM words: 1,200 of 3,533 (33%)")
    end

    it "is gone once the run isn't running" do
      start_run
      OperationProgress.where(operation_type: "scheduled_run").update_all(status: "paused")
      get system_jobs_path

      expect(Nokogiri::HTML(response.body).at_css("[data-testid='scheduled-run-step-progress']")).to be_nil
    end
  end

  # 1.84.0: one shared bar per card (system/jobs/_progress): a label line over a full-width bar.
  describe "the compactor and garbage collector bars" do
    after { CompactionRun.delete_all; OperationProgress.where(operation_type: %w[compaction garbage_collection]).delete_all }

    def html = Nokogiri::HTML(response.body)

    it "shows the compaction run's one bar, with its count, and no repeated status line" do
      op = OperationProgress.start!(operation_type: "compaction", total_count: 1_515, phase: "relationship_discovery")
      op.complete!
      CompactionRun.create!(status: "completed", phase: "relationship_discovery", operation_progress: op, stats: {},
                            started_at: 3.minutes.ago, finished_at: Time.current)

      get system_jobs_path

      card = html.at_css("[data-testid='compaction-card']")
      expect(card.css("progress").size).to eq(1)
      expect(card.at_css("[data-testid='compaction-progress'] progress")).to have_attributes(classes: include("system-progress__bar"))
      expect(card.at_css("[data-testid='compaction-progress'] progress")["value"]).to eq("100")
      expect(card.at_css("[data-testid='compaction-progress']").text.squish).to eq("Overall: 1,515 of 1,515 (100%)")
      expect(card.text).not_to include("Completed Completed", "Phase: ")
    end

    it "shows the garbage collection's bar and its status as a badge" do
      op = OperationProgress.start!(operation_type: "garbage_collection", total_count: 2, phase: "duplicates")
      op.update_progress!(current: 1)

      get system_jobs_path

      card = html.at_css("[data-testid='gc-card']")
      expect(card.at_css(".system-card__header .ui-badge").text.squish).to eq("Running")
      expect(card.at_css("[data-testid='gc-progress']").text.squish).to eq("Duplicates: 1 of 2 (50%)")
      expect(card.at_css("[data-testid='gc-progress'] progress")["value"]).to eq("50")
    end
  end
end
