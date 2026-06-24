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
