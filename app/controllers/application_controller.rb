# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_actor
  before_action :authenticate_operator!, unless: :operator_authentication_exempt?

  helper_method :operator_signed_in?

  class << self
    def operator_username
      ENV.fetch("OPERATOR_USERNAME") do
        Rails.application.credentials.dig(:operator, :username) || "operator"
      end
    end

    def operator_password
      ENV.fetch("OPERATOR_PASSWORD") do
        Rails.application.credentials.dig(:operator, :password) || "changeme"
      end
    end
  end

  private

  def set_current_actor
    Current.actor = if request.headers["X-MCP-Client"].present?
      "api:#{request.headers['X-MCP-Client']}"
    else
      "#{request.local? ? 'local' : request.remote_ip}:#{controller_name}"
    end
  end

  def operator_signed_in?
    session[:operator_signed_in] == true
  end

  def authenticate_operator!
    return if operator_signed_in?

    session[:operator_return_to] = request.fullpath if request.get?
    redirect_to operator_login_path, alert: t("operator.sessions.login_required")
  end

  def operator_authentication_exempt?
    controller_path == "operator/sessions" && action_name.in?(%w[new create])
  end

  def operator_credentials
    [ self.class.operator_username, self.class.operator_password ]
  end
end
