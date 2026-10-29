# frozen_string_literal: true

require "rails_helper"

# UI-7 S4: System › Backups. Restore needs the file name typed again, checked on the server
# (422, nothing restored). A Dir.mktmpdir folder is the backup folder; the files are synthetic.
RSpec.describe "System › Backups", type: :request do
  let(:file_name) { "202601011200_synth.sql.bz2" }

  around do |example|
    Dir.mktmpdir("synth_backups") do |dir|
      @backup_dir = dir
      AppSettings.backup_folder_path = dir
      example.run
    ensure
      AppSettings.where(var: "backup_folder_path").delete_all
      AppSettings.clear_cache
    end
  end

  def write_backup(name = file_name)
    File.join(@backup_dir, name).tap { |path| File.write(path, "synthetic backup") }
  end

  it "answers 403 to a guest and changes nothing" do
    write_backup
    enable_guest!
    sign_in_guest

    get system_backups_path
    expect(response).to have_http_status(:forbidden)
    expect { post system_restore_backup_path, params: { filename: file_name, confirmation: file_name } }.not_to(change { File.exist?(File.join(@backup_dir, file_name)) })
    expect(response).to have_http_status(:forbidden)
    delete system_backups_path, params: { filename: file_name }
    expect(response).to have_http_status(:forbidden)
    expect(File).to exist(File.join(@backup_dir, file_name))
  end

  it "sends a signed-out visitor to the sign-in page" do
    get system_backups_path

    expect(response).to redirect_to(operator_login_path)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "lists the files with a typed restore card and the backup settings" do
      write_backup

      get system_backups_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-testid='backup-row-#{file_name}']").text).to include(file_name, "MB")
      form = doc.at_css("[data-testid='typed-confirm-form-restore-#{file_name}']")
      expect(form["data-typed-confirm-expected-value"]).to eq(file_name)
      expect(form.at_css("input[name='filename']")["value"]).to eq(file_name)
      expect(doc.at_css("[data-testid='typed-confirm-restore-#{file_name}']").key?("open")).to be(false)
      expect(doc.at_css("[data-testid='setting-backup_keep_max']")).to be_present
      expect(doc.at_css("[data-testid='setting-backup_schedule_cron']")["disabled"]).to eq("disabled")
    end

    it "runs a backup now" do
      service = instance_double(BackupFileService, run_backup!: { success: true }, list: [])
      allow(BackupFileService).to receive(:new).and_return(service)

      post system_backups_path

      expect(response).to redirect_to(system_backups_path)
      expect(flash[:notice]).to include("backup completed")
      expect(service).to have_received(:run_backup!)
    end

    it "saves the backup settings, and refuses an out-of-range value with 422" do
      patch system_backup_settings_path, params: { tab: "backups", settings: { backup_keep_max: "7", enable_scheduled_backups: "1" } }
      expect(response).to redirect_to(system_backups_path)
      expect(AppSettings.backup_keep_max).to eq(7)

      patch system_backup_settings_path, params: { tab: "backups", settings: { backup_keep_max: "0", enable_scheduled_backups: "0" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-testid="setting-error-backup_keep_max"')
      AppSettings.clear_cache
      expect([ AppSettings.backup_keep_max, AppSettings.enable_scheduled_backups ]).to eq([ 7, true ])
    end

    it "restores with the typed file name, then re-reads the MCP allowlists" do
      write_backup
      service = BackupFileService.new
      allow(BackupFileService).to receive(:new).and_return(service)
      allow(service).to receive(:restore!)
      allow(GraphMem::OfficialMcp).to receive(:refresh_access!)

      post system_restore_backup_path, params: { filename: file_name, confirmation: " #{file_name} " }

      expect(response).to redirect_to(system_backups_path)
      expect(service).to have_received(:restore!).with(file_name)
      expect(GraphMem::OfficialMcp).to have_received(:refresh_access!).with(transports: true)
    end

    it "answers 422 with the card open and restores nothing on a wrong or missing confirmation" do
      write_backup
      service = BackupFileService.new
      allow(BackupFileService).to receive(:new).and_return(service)
      allow(service).to receive(:restore!)

      [ { confirmation: "202601011200_other.sql.bz2" }, { confirmation: "" }, {} ].each do |extra|
        post system_restore_backup_path, params: { filename: file_name }.merge(extra)

        expect(response).to have_http_status(:unprocessable_content)
        card = Nokogiri::HTML(response.body).at_css("[data-testid='typed-confirm-restore-#{file_name}']")
        expect(card.key?("open")).to be(true)
        expect(card.at_css("[data-testid='typed-confirm-error-restore-#{file_name}']")).to be_present
      end
      expect(service).not_to have_received(:restore!)
    end

    it "refuses a path-like file name even when it is typed" do
      allow(GraphMem::OfficialMcp).to receive(:refresh_access!)

      post system_restore_backup_path, params: { filename: "../secrets.sql.bz2", confirmation: "../secrets.sql.bz2" }

      expect(response).to redirect_to(system_backups_path)
      expect(flash[:alert]).to include("Restore failed")
      expect(GraphMem::OfficialMcp).not_to have_received(:refresh_access!)
    end

    it "deletes a listed file" do
      path = write_backup

      delete system_backups_path, params: { filename: file_name }

      expect(response).to redirect_to(system_backups_path)
      expect(File).not_to exist(path)
    end

    it "keeps the old backup routes working until §6.D-6" do
      write_backup
      get "/operator/settings?tab=database_backup"
      expect(response).to redirect_to("/system/backups")

      delete "/operator/settings/backup", params: { filename: file_name }
      expect(response).to redirect_to(system_backups_path)
      expect(File).not_to exist(File.join(@backup_dir, file_name))

      post "/operator/settings/backup/restore", params: { filename: file_name }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
