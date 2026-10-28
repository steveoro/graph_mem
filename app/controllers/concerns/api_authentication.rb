# frozen_string_literal: true

# Authenticates requests to /api/v1/*.
#
# Priority order:
#   1. Operator browser session (session[:role] == "operator", or legacy key): full access.
#   2. Bearer token matching GRAPH_MEM_MCP_TOKEN + IP allowed by McpAccessPolicy: full
#      access. No token configured → the bearer path is disabled entirely.
#   3. Guest browser session (UI-1): only GUEST_READ_ACTIONS; anything else is 403 JSON.
#      An invalid or expired guest session is reset and treated as no session.
#   Otherwise 401 (or 403 for a bearer from a disallowed IP).
#
# There is deliberately no anonymous loopback/private-range exemption: nothing
# external uses /api/v1, and a blanket LAN exemption would re-open F2.
module ApiAuthentication
  extend ActiveSupport::Concern

  # The read endpoints the Explore and Search pages use, keyed by "controller_path#action".
  GUEST_READ_ACTIONS = %w[
    api/v1/graph_data#index
    api/v1/memory_entities#index api/v1/memory_entities#show api/v1/memory_entities#search
    api/v1/memory_observations#index api/v1/memory_observations#show
    api/v1/memory_relations#index api/v1/memory_relations#show
    api/v1/search#subgraph
    api/v1/graph_traversal#traverse api/v1/graph_traversal#shortest_path
  ].freeze

  included do
    # The HTML gate in ApplicationController redirects to login; API clients
    # must never receive a redirect — replace it with the JSON 401/403.
    skip_before_action :authenticate!
    skip_before_action :authorize_role!
    before_action :authenticate_api_request!
  end

  private

  def authenticate_api_request!
    return if operator_api_session?
    return if valid_bearer_token?

    if guest_api_session?
      return if GUEST_READ_ACTIONS.include?("#{controller_path}##{action_name}")

      render json: { error: "forbidden", role: "guest" }, status: :forbidden
    elsif @bearer_ip_forbidden
      render json: { error: "Forbidden" }, status: :forbidden
    else
      response.set_header("WWW-Authenticate", 'Bearer realm="graph_mem"')
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  # Honours the operator's session expiry for API requests too.
  def operator_api_session?
    operator_signed_in? && refresh_session!(**session_limits)
  end

  def guest_api_session?
    return false unless guest_signed_in?
    return refresh_session!(**session_limits) if guest_session_valid?

    reset_session
    false
  end

  # Memoised: the CSRF check and the auth check both ask.
  def valid_bearer_token?
    return @valid_bearer_token if defined?(@valid_bearer_token)

    @valid_bearer_token = compute_valid_bearer_token
  end

  def compute_valid_bearer_token
    configured_token = ENV["GRAPH_MEM_MCP_TOKEN"].to_s.strip.presence
    return false unless configured_token

    auth_header = request.headers["Authorization"].to_s
    match = auth_header.match(/\ABearer\s+(.+)/i)
    return false unless match

    provided_token = match[1].strip
    return false unless ActiveSupport::SecurityUtils.secure_compare(provided_token, configured_token)

    policy = GraphMem::OfficialMcp.access_policy
    unless policy.request_allowed?(request, client_ip: request.remote_ip)
      @bearer_ip_forbidden = true
      return false
    end

    true
  end
end
