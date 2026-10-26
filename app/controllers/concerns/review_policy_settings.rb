# frozen_string_literal: true

# Settings › Review policies (UI-5b B2) for Operator::SettingsController: range validation of the
# review settings (from AppSettings::REVIEW_NUMBERS, for any request that carries them) and one
# AuditLog row per changed key (auditable_type "AppSettings", the setting's own row).
module ReviewPolicySettings
  extend ActiveSupport::Concern

  KEYS = (AppSettings::REVIEW_POLICY_TOGGLES.values.map(&:first) + AppSettings::REVIEW_NUMBERS.keys).freeze

  private

  # @return [String, nil] the first out-of-range review setting in `settings`, as a message
  def review_policy_settings_error(settings)
    AppSettings::REVIEW_NUMBERS.each do |key, (_default, range)|
      next unless settings.key?(key)

      raw = settings[key].to_s.strip
      value = Float(raw, exception: false)
      next if value && range.cover?(value)

      return t("operator.settings.review_policies.out_of_range", setting: t("operator.settings.fields.#{key}.label"),
                                                                 min: range.min, max: range.max, value: raw)
    end
    nil
  end

  # @return [Hash{String => Object}] the effective value of every review setting (stored, or the default)
  def review_policy_values
    stored = AppSettings.where(var: KEYS).to_h { |row| [ row.var, row.value ] }
    KEYS.index_with { |key| stored.key?(key) ? stored[key] : AppSettings.get_field(key)[:default] }
  end

  # Writes one audit row per review setting whose effective value changed.
  def audit_review_policy_changes(before)
    after = review_policy_values
    rows = AppSettings.where(var: KEYS).index_by(&:var)
    KEYS.each do |key|
      next if before[key] == after[key] || rows[key].nil?

      AuditLog.create!(auditable_type: "AppSettings", auditable_id: rows[key].id, action: "update", actor: Current.actor,
                       changed_fields: { key => { from: before[key], to: after[key] } })
    end
  end

  def render_review_policy_error(message)
    AppSettings.clear_cache
    @settings_by_group = group_settings_by_category
    @active_tab = "review_policies"
    @review_policy_error = message
    flash.now[:alert] = message
    render :index, status: :unprocessable_content
  end
end
