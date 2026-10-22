# frozen_string_literal: true

# Authenticates requests to /api/v1/*.
#
# Priority order:
#   1. Operator browser session (session[:role] == "operator", or legacy key).
#   2. Bearer token matching GRAPH_MEM_MCP_TOKEN + IP allowed by McpAccessPolicy.
#      No token configured → session-only; the bearer path is disabled entirely.
#
# There is deliberately no anonymous loopback/private-range exemption: nothing
# external uses /api/v1, and a blanket LAN exemption would re-open F2.
module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    # The HTML gate in ApplicationController redirects to login; API clients
    # must never receive a redirect — replace it with the JSON 401.
    skip_before_action :authenticate_operator!
    before_action :authenticate_api_request!
  end

  private

  IDLE_TIMEOUT    = 24.hours
  ABSOLUTE_TIMEOUT = 7.days

  def authenticate_api_request!
    return if operator_api_session?
    return if valid_bearer_token?

    response.set_header("WWW-Authenticate", 'Bearer realm="graph_mem"')
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def operator_api_session?
    role = session[:role]
    return false unless role == "operator" || session[:operator_signed_in] == true

    # Honour session expiry even for API requests.
    last_seen = session[:last_seen_at]
    signed_in = session[:signed_in_at]
    now = Time.current.to_i

    if last_seen && now - last_seen > IDLE_TIMEOUT.to_i
      reset_session
      return false
    end
    if signed_in && now - signed_in > ABSOLUTE_TIMEOUT.to_i
      reset_session
      return false
    end

    session[:last_seen_at] = now
    true
  end

  def valid_bearer_token?
    configured_token = ENV["GRAPH_MEM_MCP_TOKEN"].presence
    return false unless configured_token

    auth_header = request.headers["Authorization"].to_s
    return false unless auth_header.start_with?("Bearer ")

    provided_token = auth_header.delete_prefix("Bearer ").strip
    return false unless ActiveSupport::SecurityUtils.secure_compare(provided_token, configured_token)

    GraphMem::McpAccessPolicy.from_env(logger: Rails.logger).network_allowed?(request.remote_ip)
  end
end
