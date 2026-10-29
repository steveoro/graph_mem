# frozen_string_literal: true

require "rails_helper"

# The Maintenance hub is gone (UI-6): /maintenance redirects (301) to Projects & Data, its
# background-job cards are on /system/jobs (UI-7) and the full MCP clients table on Telemetry.
# Synthetic data only.
RSpec.describe "Maintenance hub (retired)", type: :request do
  before { sign_in_operator }

  after do
    CompactionRun.delete_all
    AgentContext.delete_all
  end

  it "redirects /maintenance to /projects, which forwards the old anchors" do
    get "/maintenance"

    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to("/projects")
    get projects_path
    targets = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-controller='legacy-anchor']")["data-legacy-anchor-targets-value"])
    expect(targets).to eq("background-jobs" => system_jobs_path, "project-scans" => projects_scans_path,
                          "mcp-clients" => system_telemetry_path(anchor: "mcp-clients"))
  end

  it "keeps the compactor and garbage collector controls on Background jobs" do
    get system_jobs_path

    jobs = Nokogiri::HTML(response.body).at_css("#background-jobs")
    expect(jobs.text).to include("Dream State / Compactor Run", "Garbage Collector")
    expect(jobs.at_css("#btn-dream-state-resume")).to be_present
    expect(jobs.at_css("#btn-gc-run")).to be_present
    expect(jobs.at_css("#btn-compaction-review")["href"]).to eq(review_path)
    expect(jobs.at_css("#btn-dream-state-refresh")["href"]).to eq(system_jobs_path)
  end

  it "shows the repair action when compaction failed with a relation error" do
    CompactionRun.create!(
      status: "failed", phase: "tree_walk", started_at: 1.hour.ago, finished_at: 30.minutes.ago,
      stats: { "error" => "Duplicate entry '266-211-part_of' for key 'index_memory_relations_uniqueness'", "entities_processed" => 40 }
    )

    get system_jobs_path

    expect(response.body).to include('id="btn-repair-relations"', "Repair relation duplicates")
  end

  it "shows the full MCP clients table on Telemetry" do
    project = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
    AgentContext.create!(client_id: "synth-client", current_project: project, last_seen_at: 1.minute.ago, last_tool_name: "set_context")

    get system_telemetry_path

    clients = Nokogiri::HTML(response.body).at_css("#mcp-clients")
    expect(clients.at_css("[data-testid='system-agent-contexts-card']")).to be_present
    expect(clients.text).to include("MCP Clients & Project Context", "synth-client", "Alpha Service", "set_context")
  end
end
