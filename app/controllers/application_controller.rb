class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_actor

  private

  def set_current_actor
    Current.actor = if request.headers["X-MCP-Client"].present?
      "api:#{request.headers['X-MCP-Client']}"
    else
      "#{request.local? ? 'local' : request.remote_ip}:#{controller_name}"
    end
  end
end
