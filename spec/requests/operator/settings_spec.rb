# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator settings", type: :request do
  let(:backup_dir) { Rails.root.join("tmp", "test_settings_backups") }

  before do
    FileUtils.mkdir_p(backup_dir)
    AppSettings.clear_cache
    AppSettings.backup_folder_path = backup_dir.to_s
  end

  after do
    FileUtils.rm_rf(backup_dir)
    AppSettings.clear_cache
  end

  describe "GET /operator/settings" do
    it "requires operator authentication" do
      get operator_settings_path

      expect(response).to redirect_to(operator_login_path)
    end

    it "renders the settings page for authenticated operators" do
      sign_in_operator
      get operator_settings_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("System Settings")
      expect(response.body).to include("Dream state / compactor")
    end
  end

  describe "PATCH /operator/settings" do
    before { sign_in_operator }

    it "updates feature flags" do
      patch operator_settings_bulk_update_path,
            params: {
              tab: "feature_flags",
              settings: {
                enable_dream_state_compactor: "0",
                enable_garbage_collector: "1"
              }
            }

      expect(response).to redirect_to(operator_settings_path(tab: "feature_flags"))
      expect(AppSettings.enable_dream_state_compactor).to be false
      expect(AppSettings.enable_garbage_collector).to be true
    end

    it "updates backup settings" do
      patch operator_settings_bulk_update_path,
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

      patch operator_settings_bulk_update_path,
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

      expect(response).to redirect_to(operator_settings_path(tab: "embeddings"))
      expect(AppSettings.embedding_url).to eq("http://embeddings.test:11434")
      expect(AppSettings.embedding_model).to eq("custom-model")
      expect(AppSettings.embedding_dims).to eq(512)
      expect(AppSettings.enable_scheduled_embedding_backfill).to be true
    end

    it "rejects invalid embedding provider" do
      patch operator_settings_bulk_update_path,
            params: {
              tab: "embeddings",
              settings: {
                embedding_provider: "invalid"
              }
            }

      expect(response).to redirect_to(operator_settings_path(tab: "embeddings"))
      follow_redirect!
      expect(response.body).to include("Invalid embedding provider")
    end

    it "renders fallback values on the embeddings tab" do
      ENV["OLLAMA_URL"] = "http://env-fallback.test:11434"
      ENV.delete("EMBEDDING_MODEL")

      get operator_settings_path(tab: "embeddings")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="embedding-fallback-url"')
      expect(response.body).to include("http://env-fallback.test:11434")
      expect(response.body).to include("nomic-embed-text")
      expect(response.body).to include('data-testid="embedding-source-env"')
      expect(response.body).to include('data-testid="embedding-source-default"')
    end

    it "updates summary settings and resets the generation client" do
      expect(SummaryGenerationClient).to receive(:reset_instance!)

      patch operator_settings_bulk_update_path,
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

      expect(response).to redirect_to(operator_settings_path(tab: "summaries"))
      expect(AppSettings.enable_llm_summarization).to be true
      expect(AppSettings.summary_model).to eq("qwen3:8b")
      expect(AppSettings.summary_timeout).to eq(20)
      expect(AppSettings.summary_observations_per_entity).to eq(3)
    end

    it "strips leading and trailing spaces from summary_model on save" do
      allow(SummaryGenerationClient).to receive(:reset_instance!)

      patch operator_settings_bulk_update_path,
            params: {
              tab: "summaries",
              settings: {
                summary_model: "  qwen3:8b  "
              }
            }

      expect(AppSettings.summary_model).to eq("qwen3:8b")
    end

    it "rejects invalid summary provider" do
      patch operator_settings_bulk_update_path,
            params: {
              tab: "summaries",
              settings: {
                summary_provider: "invalid"
              }
            }

      expect(response).to redirect_to(operator_settings_path(tab: "summaries"))
      follow_redirect!
      expect(response.body).to include("Invalid summary provider")
    end

    it "rejects an out-of-range observations_per_entity value" do
      patch operator_settings_bulk_update_path,
            params: {
              tab: "summaries",
              settings: {
                summary_observations_per_entity: "101"
              }
            }

      expect(response).to redirect_to(operator_settings_path(tab: "summaries"))
      follow_redirect!
      expect(response.body).to include("Observations per entity must be")
    end

    it "renders fallback values on the summaries tab" do
      ENV["SUMMARY_MODEL"] = "env-summary-model"

      get operator_settings_path(tab: "summaries")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="summary-fallback-model"')
      expect(response.body).to include("env-summary-model")
      expect(response.body).to include('data-testid="setting-enable_llm_summarization"')
    end
  end

  describe "POST /operator/settings/backup/run" do
    before { sign_in_operator }

    it "runs a backup for authenticated operators" do
      service = instance_double(BackupFileService, run_backup!: { success: true }, list: [])
      allow(BackupFileService).to receive(:new).and_return(service)

      post operator_run_backup_path

      expect(response).to redirect_to(operator_settings_path(tab: "database_backup"))
      follow_redirect!
      expect(response.body).to include("backup completed")
      expect(service).to have_received(:run_backup!)
    end
  end

  describe "DELETE /operator/settings/backup" do
    before { sign_in_operator }

    it "deletes a listed backup file" do
      file = backup_dir.join("202601011200_test.sql.bz2")
      File.write(file, "backup")

      delete operator_destroy_backup_path,
             params: { filename: file.basename.to_s }

      expect(response).to redirect_to(operator_settings_path(tab: "database_backup"))
      expect(file).not_to exist
    end
  end
end
