# frozen_string_literal: true

module System
  # System › Settings (UI-7 S3): one tab per SettingsSchema group of the Settings page, every
  # field rendered from the schema. `update` saves only the posted group (SettingsGroupUpdate);
  # an invalid value answers 422 with the tab re-rendered and nothing saved.
  class SettingsController < BaseController
    include SettingsGroupUpdate

    self.nav_section = :settings

    # Tab names before UI-7, still posted by an open old tab until §6.D-6.
    LEGACY_TABS = { "database_backup" => "backups", "mcp_access" => "access" }.freeze

    # GET /system/settings?tab=<group>
    def show
      AppSettings.clear_cache
      @group = settings_group
      redirect_to page_path(@group) unless @group.page == :settings
    end

    # PATCH /system/settings (tab=<group>, settings[<key>]=…)
    def update
      @group = settings_group
      return redirect_to(page_path(@group)) if save_settings_group(@group)

      if @group.page == :settings
        render :show, status: :unprocessable_content
      else
        flash[:alert] = flash.now[:alert]
        redirect_to page_path(@group)
      end
    end

    # DELETE /system/settings/legacy_scan_roots: drop the ignored pre-1.54 value.
    def clear_legacy_scan_roots
      AppSettings.where(var: "project_scan_roots").delete_all
      AppSettings.clear_cache
      flash[:notice] = t("system.settings.project_scans.legacy_cleared")
      redirect_to system_settings_path(tab: "project_scans")
    end

    def run_backup
      BackupFileService.new.run_backup!
      flash[:notice] = t("system.settings.backup.run_success")
    rescue StandardError => e
      flash[:alert] = t("system.settings.backup.run_failed", error: e.message)
    ensure
      redirect_to system_settings_path(tab: "database_backup")
    end

    def restore_backup
      BackupFileService.new.restore!(params[:filename])
      # The restored settings may carry other MCP allowlists: apply them now, not at the next restart.
      GraphMem::OfficialMcp.refresh_access!(transports: true)
      flash[:notice] = t("system.settings.backup.restore_success", filename: params[:filename])
    rescue StandardError => e
      flash[:alert] = t("system.settings.backup.restore_failed", error: e.message)
    ensure
      redirect_to system_settings_path(tab: "database_backup")
    end

    def destroy_backup
      BackupFileService.new.delete!(params[:filename])
      flash[:notice] = t("system.settings.backup.delete_success", filename: params[:filename])
    rescue StandardError => e
      flash[:alert] = t("system.settings.backup.delete_failed", error: e.message)
    ensure
      redirect_to system_settings_path(tab: "database_backup")
    end

    private

    # @return [SettingsSchema::Group] the group named by `tab`, or the first Settings tab
    def settings_group
      tab = params[:tab].to_s
      SettingsSchema.group(LEGACY_TABS.fetch(tab, tab)) || SettingsSchema.groups(page: :settings).first
    end

    # @return [String] the page showing `group`, on its tab
    def page_path(group)
      case group.page
      when :settings then system_settings_path(tab: group.key)
      else system_settings_path
      end
    end
  end
end
