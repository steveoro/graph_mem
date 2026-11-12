# frozen_string_literal: true

require "rails_helper"

# 1.81.0 in a browser: the scheduled-jobs switch starts a run after a confirmation, then offers
# Stop and shows the status line. The queued job isn't performed here (the job spec covers it).
RSpec.describe "System › Background jobs: scheduled jobs", type: :system do
  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
  end

  after { OperationProgress.where(operation_type: "scheduled_run").delete_all }

  it "starts a run after the confirmation, then offers Stop and shows the step" do
    allow(ScheduledRun).to receive(:steps).and_return(ScheduledRun.steps(env: "production"))

    visit system_jobs_path
    wait_for_stimulus
    accept_confirm { find("[data-testid='btn-scheduled-run']").click }

    expect(page).to have_text("Scheduled jobs started.")
    within("[data-testid='scheduled-run-card']") do
      expect(page).to have_css("[data-testid='btn-scheduled-run-stop']")
      expect(find("[data-testid='scheduled-run-status']")).to have_text("Step 1 of #{ScheduledRun::ORDER.size}")
      expect(page).to have_no_css("[data-testid='btn-scheduled-run']")
    end
  end

  # 1.84.0: the cards reload by themselves (every 3 s while a run is going), morphing what changed.
  it "moves the step's bar without a visit, and keeps an open <details> open" do
    row = ScheduledRunJob.start!(steps: [ ScheduledRun::Step.new(entry: "FactKeywordsJob", schedule: "every day") ])
    details = row.details.deep_dup
    details["steps"][0].merge!("outcome" => "running", "started_at" => Time.current.iso8601)
    row.update!(details: details)
    MaintenanceReport.create!(report_type: "orphans", data: { count: 1, entities: [] })

    visit system_jobs_path
    wait_for_stimulus
    expect(page).to have_css("[data-testid='scheduled-run-step-progress'] progress:not([value])")
    find("#jobs-cards details.system-card__details summary", text: "Latest GC report samples").click
    expect(page).to have_css("#jobs-cards details.system-card__details[open]")

    details["steps"][0]["progress"] = { "done" => 50, "total" => 200, "label" => "LLM words" }
    row.update!(details: details)

    expect(page).to have_css("[data-testid='scheduled-run-step-progress-label']", text: "LLM words: 50 of 200 (25%)", wait: 8)
    expect(find("[data-testid='scheduled-run-step-progress'] progress")["value"]).to eq("25")
    expect(page).to have_css("#jobs-cards details.system-card__details[open]")
  ensure
    MaintenanceReport.delete_all
  end
end
