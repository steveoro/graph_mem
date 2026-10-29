# frozen_string_literal: true

# System › Access (UI-2a A3; UI-7 SettingsGroupUpdate): the additive part of the
# three MCP allowlists. Validated wherever they come from (any error → 422, nothing saved), stored
# normalized, one AuditLog row per changed key, then applied without a restart through
# OfficialMcp.refresh_access! (a hosts or origins change also closes open MCP sessions).
module McpAccessSettings
  extend ActiveSupport::Concern

  KEYS = GraphMem::McpAccessLists::SETTING_KEYS.values.freeze
  # Keys the transports cache when they are built: changing one rebuilds them.
  TRANSPORT_KEYS = GraphMem::McpAccessLists::SETTING_KEYS.values_at(:hosts, :origins).freeze

  private

  # Validates the MCP allowlists present in `settings` and replaces each with its normalized value.
  # Collects the warnings in @mcp_access_warnings.
  #
  # @return [Hash{Symbol => Array<String>}, nil] the errors per list, or nil when all are valid
  def mcp_access_settings_errors(settings)
    @mcp_access_warnings = []
    errors = {}
    GraphMem::McpAccessLists::SETTING_KEYS.each do |kind, key|
      next unless settings.key?(key)

      result = GraphMem::McpAccessLists.validate(kind, settings[key])
      errors[kind] = result[:errors] if result[:errors].any?
      @mcp_access_warnings += result[:warnings]
      @mcp_access_warnings += result[:duplicates].map { |entry| t("system.settings.mcp_access.duplicate", entry: entry) }
      settings[key] = result[:entries].join(",")
    end
    errors.presence
  end

  # @return [Hash{String => String}] the stored value of every MCP allowlist key
  def mcp_access_values
    KEYS.index_with { |key| AppSettings.uncached_string(key) }
  end

  # Audits and applies the MCP allowlist keys whose stored value changed since `before`.
  def apply_mcp_access_changes(before)
    after = mcp_access_values
    changed = KEYS.reject { |key| before[key] == after[key] }
    return if changed.empty?

    rows = AppSettings.where(var: changed).index_by(&:var)
    changed.each do |key|
      AuditLog.create!(auditable_type: "AppSettings", auditable_id: rows.fetch(key).id, action: "update", actor: Current.actor,
                       changed_fields: { key => { from: before[key], to: after[key] } })
    end
    GraphMem::OfficialMcp.refresh_access!(transports: changed.intersect?(TRANSPORT_KEYS))
    Rails.logger.info("[McpAccessPolicy] /mcp access changed by #{Current.actor}: #{GraphMem::OfficialMcp.access_policy.describe}")
  end

  # @return [String, nil] the warnings of the last validation, as one flash sentence
  def mcp_access_warnings_notice
    t("system.settings.mcp_access.saved_with_warnings", warnings: @mcp_access_warnings.join("; ")) if @mcp_access_warnings.present?
  end
end
