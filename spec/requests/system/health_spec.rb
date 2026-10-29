# frozen_string_literal: true

require "rails_helper"

# UI-7 S5: System › Health and /system/health.json (operator only; no path, URL or host name).
RSpec.describe "System › Health", type: :request do
  it "answers 403 to a guest and sends a signed-out visitor to the sign-in page" do
    get system_health_path(format: :json)
    expect(response).to redirect_to(operator_login_path)

    enable_guest!
    sign_in_guest
    [ system_health_path, system_health_path(format: :json) ].each do |path|
      get path
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "as the operator" do
    before { sign_in_operator }

    it "redirects /system to Health" do
      get "/system"

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to("/system/health")
    end

    it "shows one row per check, status in words, and the raw snapshots collapsed" do
      get system_health_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      rows = doc.css("[data-testid^='health-'][data-status]").reject { |row| row["data-testid"] == "health-overall" }
      expect(rows.size).to eq(SystemHealth.new.checks.size)
      expect(doc.at_css("[data-testid='health-embeddings']").text).to include("Embedding service", "Problem", "unreachable")
      raw = doc.at_css("details[data-testid='health-raw-snapshots']")
      expect(raw.key?("open")).to be(false)
      expect(raw.text).to include("MaintenanceDashboardSnapshot", "EmbeddingStatusSnapshot", "ScanRootPolicy.status")
    end

    it "answers the JSON shape, with no path, URL or host name" do
      with_scan_home do |home|
        Dir.mktmpdir("synth_backups") do |dir|
          AppSettings.backup_folder_path = dir
          AppSettings.embedding_url = "http://synth-embeddings.test:9"

          get system_health_path(format: :json)

          body = response.parsed_body
          expect(body.keys).to eq(%w[version status generated_at checks])
          expect(body["version"]).to eq(GraphMem::VERSION)
          expect(body["status"]).to be_in(%w[ok warn danger])
          expect(Time.iso8601(body["generated_at"])).to be_within(1.minute).of(Time.current)
          expect(body["checks"]).to all(match("key" => String, "status" => be_in(HomeSnapshot::Health::STATUSES.map(&:to_s)), "value" => String))
          expect(response.body).not_to include(home, dir, "synth-embeddings.test", "http")
        ensure
          AppSettings.where(var: %w[backup_folder_path embedding_url]).delete_all
          AppSettings.clear_cache
          EmbeddingService.reset_instance!
        end
      end
    end
  end
end
