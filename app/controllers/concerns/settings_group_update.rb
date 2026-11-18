# frozen_string_literal: true

# Saves one SettingsSchema group from a form post (UI-7 S2), for the Settings, Backups and Access
# pages. Only the posted group's writable keys are read from `params[:settings]`; any invalid
# value → nothing is saved and the page re-renders (422) with the bad fields marked. After a
# save: the review-policy and MCP audit rows, the MCP access refresh and the embedding/summary
# client resets, as Operator::SettingsController did.
module SettingsGroupUpdate
  extend ActiveSupport::Concern
  include ReviewPolicySettings
  include McpAccessSettings

  private

  # @param group [SettingsSchema::Group]
  # @return [Boolean] true when saved (flash[:notice] set); false with @settings_errors,
  #   @posted_settings and flash.now[:alert] set for the 422 re-render
  def save_settings_group(group)
    raw = params[:settings].is_a?(ActionController::Parameters) ? params[:settings] : ActionController::Parameters.new
    posted = raw.permit(*group.writable_keys).to_h
    @posted_settings = posted
    @settings_errors = SettingsSchema.errors(group, posted)
    alert = @settings_errors.values.join(" ").presence || (send(group.check, posted) if group.check)
    if alert
      AppSettings.clear_cache
      flash.now[:alert] = alert
      return false
    end

    write_settings(group, posted)
    flash[:notice] = [ t("system.settings.bulk_update.success", count: posted.size), mcp_access_warnings_notice ].compact.join(" ")
    true
  end

  def write_settings(group, posted)
    review_before = review_policy_values
    mcp_before = mcp_access_values
    apps_before = AppSettings.mcp_apps_enabled?
    skills_before = AppSettings.mcp_skills_enabled?
    posted.each { |key, raw| AppSettings.public_send("#{key}=", SettingsSchema.cast(SettingsSchema.field(key), raw)) }
    AppSettings.clear_cache
    audit_review_policy_changes(review_before)
    apply_mcp_access_changes(mcp_before)
    apply_mcp_extension_changes(apps_before, skills_before)
    EmbeddingService.reset_instance! if group.key == :embeddings
    SummaryGenerationClient.reset_instance! if group.key == :summaries
  end

  # MCP Apps (1.87.0) and Skills over MCP (1.91.0) on or off: the HTTP servers are rebuilt with the
  # new values, which closes the open MCP sessions, once per save however many changed; nothing
  # happens when neither changed. In-process only, like the access refresh; a stdio runner needs a
  # restart.
  def apply_mcp_extension_changes(apps_before, skills_before)
    apps_after = AppSettings.mcp_apps_enabled?
    skills_after = AppSettings.mcp_skills_enabled?
    return if apps_before == apps_after && skills_before == skills_after

    GraphMem::OfficialMcp.refresh_access!(transports: true)
    Rails.logger.info("[McpApps] MCP Apps #{apps_after ? 'on' : 'off'} (#{Current.actor}); MCP servers rebuilt") if apps_before != apps_after
    Rails.logger.info("[McpSkills] Skills over MCP #{skills_after ? 'on' : 'off'} (#{Current.actor}); MCP servers rebuilt") if skills_before != skills_after
  end

  # SettingsSchema check of the review policies group (ReviewPolicySettings).
  def check_review_policies(posted)
    review_policy_settings_error(posted)
  end

  # SettingsSchema check of the access group (McpAccessSettings): normalizes the lists in place.
  def check_mcp_access(posted)
    @mcp_access_errors = mcp_access_settings_errors(posted)
    t("system.settings.mcp_access.not_saved", errors: @mcp_access_errors.values.flatten.join("; ")) if @mcp_access_errors
  end
end
