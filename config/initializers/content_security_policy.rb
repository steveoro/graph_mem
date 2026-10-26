# Be sure to restart your server when you modify this file.
#
# Content Security Policy, enforced since UI-1 / 1.56.0 (report-only in UI-0, F1).
# Violations are still reported to /csp-reports and logged.

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # Nonce is auto-appended by the middleware via content_security_policy_nonce_directives below.
    policy.script_src  :self
    # Tailwind v4 and Cytoscape require inline styles.
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self, :ws, :wss
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self
    policy.report_uri "/csp-reports"
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(36) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Enforced since UI-1 / 1.56.0 (no content_security_policy_report_only).
end
