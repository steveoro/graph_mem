# frozen_string_literal: true

require "rails_helper"

# The maintenance hub: export, import and cleanup, plus the controls that moved off Home in
# UI-2b (compactor, garbage collection, relation repair, project scans, MCP clients, reports).
# Synthetic data only.
RSpec.describe "Maintenance hub", type: :request do
  before { sign_in_operator }

  after do
    CompactionRun.delete_all
    AgentContext.delete_all
  end

  it "renders export, import and cleanup" do
    MemoryEntity.create!(name: "ExportRoot", entity_type: "Project")

    get maintenance_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Maintenance Hub")
    expect(response.body).to include('id="btn-maintenance-import"', 'id="btn-maintenance-export"', 'id="btn-maintenance-choose-file"')
    expect(response.body).to include('data-testid="btn-maintenance-choose-file"', "Choose JSON file", 'id="maintenance-import-file"')
    expect(response.body).to include('class="maintenance-export-form"', 'data-turbo="false"', export_data_exchange_index_path)
    expect(response.body).to include(%(href="#{root_path}"))
  end

  it "carries the compactor and garbage collector controls" do
    get maintenance_path

    body = Nokogiri::HTML(response.body)
    jobs = body.at_css("#background-jobs")
    expect(jobs.text).to include("Dream State / Compactor Run", "Garbage Collector")
    expect(jobs.at_css("#btn-dream-state-resume")).to be_present
    expect(jobs.at_css("#btn-gc-run")).to be_present
    expect(jobs.at_css("#btn-compaction-review")["href"]).to eq(review_path)
    expect(jobs.at_css("#btn-dream-state-refresh")["href"]).to eq(maintenance_path(anchor: "background-jobs"))
  end

  it "shows the repair action when compaction failed with a relation error" do
    CompactionRun.create!(
      status: "failed", phase: "tree_walk", started_at: 1.hour.ago, finished_at: 30.minutes.ago,
      stats: { "error" => "Duplicate entry '266-211-part_of' for key 'index_memory_relations_uniqueness'", "entities_processed" => 40 }
    )

    get maintenance_path

    expect(response.body).to include('id="btn-repair-relations"', "Repair relation duplicates")
  end

  it "lists recent project scans with the scan form" do
    project = MemoryEntity.create!(name: "synth-widget", entity_type: "Project")
    OperationProgress.create!(
      operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "completed",
      total_count: 5, current_count: 5, percentage: 100.0, phase: "completed",
      details: { "project_name" => "synth-widget", "mode" => "initial", "project_entity_id" => project.id, "fallback" => false }
    )

    get maintenance_path

    scans = Nokogiri::HTML(response.body).at_css("#project-scans")
    expect(scans.at_css("[data-testid='dashboard-project-scans-card']")).to be_present
    expect(scans.at_css("[data-testid='project-scan-trigger-form']")["action"]).to eq(project_scans_path)
    expect(scans.at_css("[data-testid='project-scan-skill-form']")["action"]).to eq(project_scan_skills_path)
    expect(scans.text).to include("Project Scans", "synth-widget", "Completed", "initial")
    expect(scans.at_css("#btn-project-scans-review")["href"]).to eq(review_path(view: "scan"))
  end

  it "wires active project scan rows for live progress updates" do
    OperationProgress.create!(
      operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "running",
      total_count: 5, current_count: 1, percentage: 20.0, phase: "discovering_files", message: "Discovering project files",
      details: { "project_name" => "synth-widget", "mode" => "initial" }
    )

    get maintenance_path

    expect(response.body).to include('data-controller="operation-progress"', "data-progress-status", "data-progress-phase", "data-progress-percentage")
  end

  it "lists pending scan reviews and sends decisions to Review, with no approve or dismiss here" do
    entity = MemoryEntity.create!(name: "StaleTask", entity_type: "Task")
    report = MaintenanceReport.create!(report_type: "scan_review", data: { "source" => "test" })
    MaintenanceReportRow.create!(
      maintenance_report: report, report_type: "scan_review", row_uuid: "scan-review-hub-1", kind: "delete_entity", status: "active",
      signature: CompactionReviewService.signature_for("delete_entity", { entity_id: entity.id }),
      payload: { "entity_id" => entity.id, "reason" => "not found in project scan" }
    )

    get maintenance_path

    section = Nokogiri::HTML(response.body).at_css("[data-testid='dashboard-scan-reviews-section']")
    expect(section.text).to include("StaleTask")
    expect(section.css("form")).to be_empty
    expect(response.body).to include(review_path(view: "scan"))
  end

  it "shows the full MCP clients table" do
    project = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
    AgentContext.create!(client_id: "synth-client", current_project: project, last_seen_at: 1.minute.ago, last_tool_name: "set_context")

    get maintenance_path

    clients = Nokogiri::HTML(response.body).at_css("#mcp-clients")
    expect(clients.at_css("[data-testid='dashboard-agent-contexts-card']")).to be_present
    expect(clients.text).to include("MCP Clients & Project Context", "synth-client", "Alpha Service", "set_context")
  end
end
