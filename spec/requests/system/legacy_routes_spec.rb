# frozen_string_literal: true

require "rails_helper"

# UI-7 shims, kept until §6.D-6: the old operator pages answer 301 to their System page, and the
# old writes still reach the System actions (an open old tab keeps working).
RSpec.describe "System › old routes", type: :request do
  before { sign_in_operator }

  after { AppSettings.clear_cache }

  {
    "/operator/settings?tab=telemetry" => "/system/settings?tab=telemetry",
    "/operator/embeddings" => "/system/embeddings",
    "/operator/telemetry?since_days=7" => "/system/telemetry?since_days=7",
    "/operator/audit_logs?since_days=30" => "/system/audit_log?since_days=30",
    "/operator/settings/project_scans/check_path?path=Projects" => "/projects/scans/check_path?path=Projects",
    "/projects/jobs" => "/system/jobs",
    "/operator/jobs" => "/system/queue",
    "/operator/jobs/applications/1/jobs" => "/system/queue/applications/1/jobs",
    "/operator/jobs/applications/1/jobs?status=failed" => "/system/queue/applications/1/jobs?status=failed"
  }.each do |old, new|
    it "redirects GET #{old} (301) to #{new}" do
      get old

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(new)
    end
  end

  it "routes the old writes to the System actions" do
    patch "/operator/settings", params: { tab: "telemetry", settings: { tool_invocation_retention_days: "45" } }
    expect(response).to redirect_to(system_settings_path(tab: "telemetry"))
    expect(AppSettings.uncached_string("tool_invocation_retention_days")).to eq("45")

    post "/operator/telemetry/prune"
    expect(URI(response.location).path).to eq(system_telemetry_path)

    post "/operator/audit_logs/prune", params: { confirmation: "0" }
    expect(URI(response.location).path).to eq(system_audit_log_path)

    AppSettings.enable_garbage_collector = false
    post "/operator/maintenance/garbage_collection/run"
    expect(response).to redirect_to(system_jobs_path)
  end
end
