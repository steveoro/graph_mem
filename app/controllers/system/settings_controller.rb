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
      when :backups then system_backups_path
      when :access then system_access_path
      else system_settings_path
      end
    end
  end
end
