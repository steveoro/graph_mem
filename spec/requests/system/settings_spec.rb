# frozen_string_literal: true

require "rails_helper"

RSpec.describe "System › Settings", type: :request do
  let(:backup_dir) { Rails.root.join("tmp", "test_settings_backups") }

  # Examples below set fallback ENV values; restore them so later specs don't call those URLs.
  around do |example|
    original = %w[OLLAMA_URL EMBEDDING_MODEL SUMMARY_MODEL].to_h { |key| [ key, ENV[key] ] }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before do
    FileUtils.mkdir_p(backup_dir)
    AppSettings.clear_cache
    AppSettings.backup_folder_path = backup_dir.to_s
  end

  after do
    FileUtils.rm_rf(backup_dir)
    AppSettings.clear_cache
  end

  describe "GET /system/settings" do
    it "requires operator authentication" do
      get system_settings_path

      expect(response).to redirect_to(operator_login_path)
    end

    it "renders the settings page for authenticated operators" do
      sign_in_operator
      get system_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Settings", "Feature flags, embeddings")
      expect(response.body).to include("Dream state / compactor")
    end

    it "renders the telemetry retention settings tab" do
      sign_in_operator
      get system_settings_path(tab: "telemetry")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="operator-settings-tab-telemetry"')
      expect(response.body).to include('data-testid="setting-tool_invocation_retention_days"')
      expect(response.body).to include('data-testid="setting-compaction_review_row_retention_days"')
    end
  end

  describe "PATCH /system/settings" do
    before { sign_in_operator }

    it "updates telemetry retention" do
      patch system_settings_path,
            params: {
              tab: "telemetry",
              settings: { tool_invocation_retention_days: "120" }
            }

      expect(response).to redirect_to(system_settings_path(tab: "telemetry"))
      expect(AppSettings.tool_invocation_retention_days).to eq(120)
    ensure
      AppSettings.tool_invocation_retention_days = 90
    end

    it "updates review row retention" do
      patch system_settings_path,
            params: {
              tab: "telemetry",
              settings: { compaction_review_row_retention_days: "45" }
            }

      expect(response).to redirect_to(system_settings_path(tab: "telemetry"))
      expect(AppSettings.compaction_review_row_retention_days).to eq(45)
    ensure
      AppSettings.compaction_review_row_retention_days = 30
    end

    it "updates feature flags" do
      patch system_settings_path,
            params: {
              tab: "feature_flags",
              settings: {
                enable_dream_state_compactor: "0",
                enable_garbage_collector: "1"
              }
            }

      expect(response).to redirect_to(system_settings_path(tab: "feature_flags"))
      expect(AppSettings.enable_dream_state_compactor).to be false
      expect(AppSettings.enable_garbage_collector).to be true
    end

    it "updates backup settings" do
      patch system_settings_path,
            params: {
              tab: "database_backup",
              settings: {
                backup_folder_path: "tmp/custom_backups",
                backup_keep_max: "7",
                enable_scheduled_backups: "1"
              }
            }

      expect(AppSettings.backup_folder_path).to eq("tmp/custom_backups")
      expect(AppSettings.backup_keep_max).to eq(7)
      expect(AppSettings.enable_scheduled_backups).to be true
    end

    it "updates embedding settings and resets the service instance" do
      expect(EmbeddingService).to receive(:reset_instance!)

      patch system_settings_path,
            params: {
              tab: "embeddings",
              settings: {
                embedding_url: "http://embeddings.test:11434",
                embedding_model: "custom-model",
                embedding_provider: "ollama",
                embedding_dims: "512",
                enable_scheduled_embedding_backfill: "1"
              }
            }

      expect(response).to redirect_to(system_settings_path(tab: "embeddings"))
      expect(AppSettings.embedding_url).to eq("http://embeddings.test:11434")
      expect(AppSettings.embedding_model).to eq("custom-model")
      expect(AppSettings.embedding_dims).to eq(512)
      expect(AppSettings.enable_scheduled_embedding_backfill).to be true
    end

    it "rejects invalid embedding provider" do
      patch system_settings_path,
            params: {
              tab: "embeddings",
              settings: {
                embedding_provider: "invalid"
              }
            }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Invalid embedding provider")
    end

    it "renders fallback values on the embeddings tab" do
      ENV["OLLAMA_URL"] = "http://env-fallback.test:11434"
      ENV.delete("EMBEDDING_MODEL")

      get system_settings_path(tab: "embeddings")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="embedding-fallback-url"')
      expect(response.body).to include("http://env-fallback.test:11434")
      expect(response.body).to include("nomic-embed-text")
      expect(response.body).to include('data-testid="embedding-source-env"')
      expect(response.body).to include('data-testid="embedding-source-default"')
    end

    it "updates summary settings and resets the generation client" do
      expect(SummaryGenerationClient).to receive(:reset_instance!)

      patch system_settings_path,
            params: {
              tab: "summaries",
              settings: {
                enable_llm_summarization: "1",
                summary_url: "http://summary.test:11434",
                summary_model: "qwen3:8b",
                summary_provider: "ollama",
                summary_timeout: "20",
                summary_max_tokens: "128",
                summary_observations_per_entity: "3"
              }
            }

      expect(response).to redirect_to(system_settings_path(tab: "summaries"))
      expect(AppSettings.enable_llm_summarization).to be true
      expect(AppSettings.summary_model).to eq("qwen3:8b")
      expect(AppSettings.summary_timeout).to eq(20)
      expect(AppSettings.summary_observations_per_entity).to eq(3)
    end

    it "strips leading and trailing spaces from summary_model on save" do
      allow(SummaryGenerationClient).to receive(:reset_instance!)

      patch system_settings_path,
            params: {
              tab: "summaries",
              settings: {
                summary_model: "  qwen3:8b  "
              }
            }

      expect(AppSettings.summary_model).to eq("qwen3:8b")
    end

    it "rejects invalid summary provider" do
      patch system_settings_path,
            params: {
              tab: "summaries",
              settings: {
                summary_provider: "invalid"
              }
            }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Invalid summary provider")
    end

    it "rejects an out-of-range observations_per_entity value" do
      patch system_settings_path,
            params: {
              tab: "summaries",
              settings: {
                summary_observations_per_entity: "101"
              }
            }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Observations per entity must be")
    end

    it "renders fallback values on the summaries tab" do
      ENV["SUMMARY_MODEL"] = "env-summary-model"

      get system_settings_path(tab: "summaries")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="summary-fallback-model"')
      expect(response.body).to include("env-summary-model")
      expect(response.body).to include('data-testid="setting-enable_llm_summarization"')
    end

    it "updates import observation duplicate distance from the slider" do
      patch system_settings_path,
            params: {
              tab: "imports",
              settings: {
                import_observation_duplicate_max_distance: "0.42"
              }
            }

      expect(response).to redirect_to(system_settings_path(tab: "imports"))
      expect(AppSettings.import_observation_duplicate_max_distance).to eq(0.42)
    end

    it "rejects an import observation duplicate distance outside the slider range" do
      patch system_settings_path,
            params: {
              tab: "imports",
              settings: {
                import_observation_duplicate_max_distance: "0.51"
              }
            }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Observation duplicate distance must be between 0.20 and 0.50")
    end

    it "renders the import duplicate distance slider" do
      get system_settings_path(tab: "imports")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="setting-import_observation_duplicate_max_distance"')
      expect(response.body).to include('data-testid="import-observation-duplicate-distance-value"')
    end

    it "renders the project scans tab: folders, filter, check-a-path and the always-blocked list" do
      with_scan_home do |home|
        get system_settings_path(tab: "project_scans")

        expect(response).to have_http_status(:ok)
        body = response.body
        expect(body).to include('data-testid="operator-settings-tab-project_scans"', 'data-testid="setting-project_scan_subfolders"',
                                'data-testid="scan-check-path"', 'data-testid="scan-always-blocked"', home)
        expect(body).not_to include('data-testid="setting-project_scan_roots"')
      end
    end

    def save_subfolders(value)
      patch system_settings_path, params: { tab: "project_scans", settings: { project_scan_subfolders: value } }
    end

    it "stores absolute entries under the scan folder as relative ones" do
      with_scan_home do |home|
        save_subfolders("#{home}/Projects, work/clients")

        expect(response).to redirect_to(system_settings_path(tab: "project_scans"))
        expect(AppSettings.project_scan_subfolders_raw).to eq("Projects, work/clients")
      end
    end

    it "rejects bad entries one by one and keeps the old value" do
      with_scan_home do
        save_subfolders("../x, /etc, .ssh, Projects/.git")
        expect(response).to have_http_status(:unprocessable_content)

        expect(response.body).to include("../x contains", "/etc is outside the scan root", ".ssh is inside a hidden",
                                         "Projects/.git is inside a hidden")
        expect(AppSettings.project_scan_subfolders_raw).to eq("Projects")
      end
    end

    it "saves a missing folder and shows it as missing, and allows a blank filter with a warning" do
      with_scan_home do
        save_subfolders("Projects, someday")
        get system_settings_path(tab: "project_scans")
        expect(response.body).to include("someday").and include("missing")

        save_subfolders("")
        get system_settings_path(tab: "project_scans")
        expect(response.body).to include('data-testid="whole-home-warning"')
      end
    end

    it "shows and clears a leftover legacy project_scan_roots value" do
      AppSettings.project_scan_roots = "/srv/code"
      get system_settings_path(tab: "project_scans")
      expect(response.body).to include('data-testid="legacy-scan-roots"', "/srv/code")

      delete system_clear_legacy_scan_roots_path

      expect(AppSettings.legacy_project_scan_roots).to be_nil
    end
  end

  describe "GET /projects/scans/check_path" do
    before { sign_in_operator }

    it "renders each policy code inside the Turbo Frame" do
      with_scan_home do |home|
        FileUtils.mkdir_p(File.join(home, "Projects", "alpha"))
        FileUtils.mkdir_p(File.join(home, ".ssh"))
        {
          File.join(home, "Projects", "alpha") => "ok",
          File.join(home, ".ssh") => "denied",
          "/etc" => "not_mounted",
          File.join(home, "Projects", "nope") => "not_found"
        }.each do |path, code|
          get check_path_projects_scans_path(path: path)

          expect(response.body).to include('id="scan-path-check"', %(data-code="#{code}"))
        end
      end
    end
  end

  describe "POST /system/settings/backup/run" do
    before { sign_in_operator }

    it "runs a backup for authenticated operators" do
      service = instance_double(BackupFileService, run_backup!: { success: true }, list: [])
      allow(BackupFileService).to receive(:new).and_return(service)

      post operator_run_backup_path

      expect(response).to redirect_to(system_settings_path(tab: "database_backup"))
      follow_redirect!
      expect(response.body).to include("backup completed")
      expect(service).to have_received(:run_backup!)
    end
  end

  describe "POST /system/settings/backup/restore" do
    before { sign_in_operator }

    # UI-2a: a restored settings table may carry other MCP allowlists; they apply at once.
    it "re-reads the MCP allowlists after a successful restore, and not after a failed one" do
      service = instance_double(BackupFileService, list: [])
      allow(service).to receive(:restore!).with("202601011200_synth.sql.bz2")
      allow(service).to receive(:restore!).with("missing.sql.bz2").and_raise(ArgumentError, "not found")
      allow(BackupFileService).to receive(:new).and_return(service)
      allow(GraphMem::OfficialMcp).to receive(:refresh_access!)

      post operator_restore_backup_path, params: { filename: "202601011200_synth.sql.bz2" }

      expect(response).to redirect_to(system_settings_path(tab: "database_backup"))
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).with(transports: true).once

      post operator_restore_backup_path, params: { filename: "missing.sql.bz2" }

      expect(flash[:alert]).to include("not found")
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).once
    end
  end

  describe "DELETE /system/settings/backup" do
    before { sign_in_operator }

    it "deletes a listed backup file" do
      file = backup_dir.join("202601011200_test.sql.bz2")
      File.write(file, "backup")

      delete operator_destroy_backup_path,
             params: { filename: file.basename.to_s }

      expect(response).to redirect_to(system_settings_path(tab: "database_backup"))
      expect(file).not_to exist
    end
  end
end
