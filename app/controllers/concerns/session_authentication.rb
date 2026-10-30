# frozen_string_literal: true

# Browser-session sign-in state shared by the HTML controllers (ApplicationController) and
# the JSON API (ApiAuthentication). Two roles: "operator" (full access) and "guest"
# (read-only, UI-1; see RoleAuthorization and GraphMem::GuestCredentials).
module SessionAuthentication
  extend ActiveSupport::Concern

  OPERATOR_IDLE_TIMEOUT     = 24.hours
  OPERATOR_ABSOLUTE_TIMEOUT = 7.days
  GUEST_IDLE_TIMEOUT        = 2.hours
  GUEST_ABSOLUTE_TIMEOUT    = 24.hours

  included do
    helper_method :operator_signed_in?, :guest_signed_in?, :signed_in?, :current_role
  end

  private

  # @return [String, nil] "operator", "guest" or nil, from the session's role key
  def current_role
    return "operator" if session[:role] == "operator"
    return "guest" if session[:role] == "guest"

    nil
  end

  def operator_signed_in?
    current_role == "operator"
  end

  def guest_signed_in?
    current_role == "guest"
  end

  def signed_in?
    current_role.present?
  end

  # A guest session stays valid only while guest access is available and the configured
  # credentials still match the ones it signed in with.
  # @return [Boolean]
  def guest_session_valid?
    credentials = GraphMem::GuestCredentials.current
    credentials.available? &&
      ActiveSupport::SecurityUtils.secure_compare(session[:guest_cred_fp].to_s, credentials.fingerprint)
  end

  # @return [Hash{Symbol=>ActiveSupport::Duration}] idle: and absolute: limits for the current role
  def session_limits
    if guest_signed_in?
      { idle: GUEST_IDLE_TIMEOUT, absolute: GUEST_ABSOLUTE_TIMEOUT }
    else
      { idle: OPERATOR_IDLE_TIMEOUT, absolute: OPERATOR_ABSOLUTE_TIMEOUT }
    end
  end

  # @return [Boolean] true when the session is past its idle or absolute limit
  def session_expired?(idle:, absolute:)
    now = Time.current.to_i
    last_seen = session[:last_seen_at]
    signed_in = session[:signed_in_at]
    (last_seen && now - last_seen > idle.to_i) || (signed_in && now - signed_in > absolute.to_i) || false
  end

  # Resets an expired session, or records activity on a live one.
  # @return [Boolean] whether the session is still alive
  def refresh_session!(idle:, absolute:)
    if session_expired?(idle: idle, absolute: absolute)
      reset_session
      false
    else
      session[:last_seen_at] = Time.current.to_i
      true
    end
  end
end
