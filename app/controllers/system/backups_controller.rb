# frozen_string_literal: true

module System
  # System › Backups (UI-7 S4): the backup settings (SettingsSchema's backups group), "Run backup
  # now", and the files with a typed-confirmation Restore and a Delete. BackupFileService stays
  # the only way to a file (SAFE_BACKUP_FILENAME, resolve_safe_path!).
  class BackupsController < BaseController
    include SettingsGroupUpdate
    include TypedConfirmation

    self.nav_section = :backups

    # GET /system/backups
    def index
      load_page
    end

    # POST /system/backups: run a backup now
    def create
      BackupFileService.new.run_backup!
      redirect_to system_backups_path, notice: t("system.settings.backup.run_success")
    rescue StandardError => e
      redirect_to system_backups_path, alert: t("system.settings.backup.run_failed", error: e.message)
    end

    # PATCH /system/backups/settings
    def update_settings
      return redirect_to(system_backups_path) if save_settings_group(SettingsSchema.group(:backups))

      load_page
      render :index, status: :unprocessable_content
    end

    # POST /system/backups/restore (filename=, confirmation= the file name typed again)
    def restore
      filename = params[:filename].to_s
      unless typed_confirmation?(filename)
        typed_confirmation_failed!("restore-#{filename}")
        load_page
        return render :index, status: :unprocessable_content
      end

      BackupFileService.new.restore!(filename)
      # The restored settings may carry other MCP allowlists: apply them now, not at the next restart.
      GraphMem::OfficialMcp.refresh_access!(transports: true)
      redirect_to system_backups_path, notice: t("system.settings.backup.restore_success", filename: filename)
    rescue StandardError => e
      redirect_to system_backups_path, alert: t("system.settings.backup.restore_failed", error: e.message)
    end

    # DELETE /system/backups (filename=)
    def destroy
      BackupFileService.new.delete!(params[:filename])
      redirect_to system_backups_path, notice: t("system.settings.backup.delete_success", filename: params[:filename])
    rescue StandardError => e
      redirect_to system_backups_path, alert: t("system.settings.backup.delete_failed", error: e.message)
    end

    private

    def load_page
      AppSettings.clear_cache
      @group = SettingsSchema.group(:backups)
      @backup_files = BackupFileService.new.list
    end
  end
end
