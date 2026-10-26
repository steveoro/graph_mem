# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include SessionAuthentication
  include RoleAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_actor
  before_action :authenticate!, unless: :authentication_exempt?
  before_action :authorize_role!, unless: :authentication_exempt?

  SESSION_IDLE_TIMEOUT     = SessionAuthentication::OPERATOR_IDLE_TIMEOUT
  SESSION_ABSOLUTE_TIMEOUT = SessionAuthentication::OPERATOR_ABSOLUTE_TIMEOUT
  GUEST_IDLE_TIMEOUT       = SessionAuthentication::GUEST_IDLE_TIMEOUT
  GUEST_ABSOLUTE_TIMEOUT   = SessionAuthentication::GUEST_ABSOLUTE_TIMEOUT

  class << self
    def operator_username
      ENV["OPERATOR_USERNAME"].presence ||
        Rails.application.credentials.dig(:operator, :username) ||
        "operator"
    end

    def operator_password
      ENV["OPERATOR_PASSWORD"].presence ||
        Rails.application.credentials.dig(:operator, :password) ||
        "changeme"
    end
  end

  private

  def set_current_actor
    Current.actor = if request.headers["X-MCP-Client"].present?
      "api:#{request.headers['X-MCP-Client']}"
    elsif operator_signed_in?
      "operator:#{session[:user] || 'unknown'}@#{request.remote_ip}"
    elsif guest_signed_in?
      "guest:#{session[:user]}@#{request.remote_ip}"
    else
      "#{request.local? ? 'local' : request.remote_ip}:#{controller_name}"
    end
  end

  # Signed out → login (remembering a GET); guest whose access was withdrawn → signed out;
  # otherwise the role's idle/absolute expiry applies.
  def authenticate!
    unless signed_in?
      session[:operator_return_to] = request.fullpath if request.get?
      redirect_to main_app.operator_login_path, alert: t("operator.sessions.login_required")
      return
    end

    if guest_signed_in? && !guest_session_valid?
      reset_session
      redirect_to main_app.operator_login_path, alert: t("operator.sessions.guest_disabled")
      return
    end

    enforce_session_expiry!(**session_limits)
  end

  def enforce_session_expiry!(idle:, absolute:)
    return if refresh_session!(idle: idle, absolute: absolute)

    redirect_to main_app.operator_login_path, alert: t("operator.sessions.session_expired")
  end

  def authentication_exempt?
    controller_path == "operator/sessions" && action_name.in?(%w[new create])
  end

  def operator_credentials
    [ self.class.operator_username, self.class.operator_password ]
  end
end
