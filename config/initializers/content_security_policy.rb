# Be sure to restart your server when you modify this file.
#
# UI-0: CSP enabled as report-only (F1 / §6 UI-0 §1.5).
# Enforcement switches to enforced in UI-1 once inline handlers are removed.

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
    policy.report_uri "/csp-reports"
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(36) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Report-only in 1.53.0; enforced in UI-1 (1.55.0) once inline handlers are gone.
  config.content_security_policy_report_only = true
end
