# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include RoleAuthorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_actor
  before_action :authenticate_operator!, unless: :operator_authentication_exempt?

  helper_method :operator_signed_in?

  SESSION_IDLE_TIMEOUT     = 24.hours
  SESSION_ABSOLUTE_TIMEOUT = 7.days

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
    else
      "#{request.local? ? 'local' : request.remote_ip}:#{controller_name}"
    end
  end

  def operator_signed_in?
    # Accept new role key or legacy operator_signed_in key (existing sessions).
    return true if session[:role] == "operator"
    return true if session[:operator_signed_in] == true
    false
  end

  def authenticate_operator!
    if operator_signed_in?
      enforce_session_expiry!
    else
      session[:operator_return_to] = request.fullpath if request.get?
      redirect_to operator_login_path, alert: t("operator.sessions.login_required")
    end
  end

  def enforce_session_expiry!
    last_seen = session[:last_seen_at]
    signed_in = session[:signed_in_at]
    now = Time.current.to_i

    if last_seen && now - last_seen > SESSION_IDLE_TIMEOUT.to_i
      reset_session
      redirect_to operator_login_path, alert: t("operator.sessions.session_expired")
      return
    end

    if signed_in && now - signed_in > SESSION_ABSOLUTE_TIMEOUT.to_i
      reset_session
      redirect_to operator_login_path, alert: t("operator.sessions.session_expired")
      return
    end

    session[:last_seen_at] = now
  end

  def operator_authentication_exempt?
    controller_path == "operator/sessions" && action_name.in?(%w[new create])
  end

  def operator_credentials
    [ self.class.operator_username, self.class.operator_password ]
  end
end
