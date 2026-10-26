# frozen_string_literal: true

# Caps how often read-only guests can search (UI-1b): a vector query costs an embedding
# call, and the guest password may be shared. Operators and bearer-token clients aren't
# limited. Two budgets cover every throttled action (HTML and API):
# - per IP: LIMIT a PERIOD;
# - for all guests together (keyed on the shared credential's fingerprint): GLOBAL_LIMIT a
#   PERIOD, so forged X-Forwarded-For values or rotating IPv6 addresses can't escape it.
#
# Usage:
#   class SearchController < ApplicationController
#     include GuestSearchThrottle
#     throttle_guest_search :results
#   end
module GuestSearchThrottle
  extend ActiveSupport::Concern

  LIMIT = 60
  GLOBAL_LIMIT = LIMIT * 5
  PERIOD = 1.minute
  # Actions that embed only when given a query (memory_entities#show ranks observations
  # against ?query=); without it they aren't counted.
  QUERY_GATED_ACTIONS = %w[show].freeze

  class_methods do
    # @param actions [Array<Symbol>] the search actions to throttle for guests
    def throttle_guest_search(*actions)
      throttled = { only: actions, scope: "guest-search", if: :guest_search_throttled?,
                    with: -> { render_guest_search_throttled } }
      rate_limit to: LIMIT, within: PERIOD, **throttled
      rate_limit to: GLOBAL_LIMIT, within: PERIOD, name: "all-guests",
                 by: -> { session[:guest_cred_fp].to_s }, **throttled
    end
  end

  private

  # A guest session, unless the request also carries a valid bearer token (API only).
  def guest_search_throttled?
    return false if action_name.in?(QUERY_GATED_ACTIONS) && params[:query].blank?

    guest_signed_in? && !(respond_to?(:valid_bearer_token?, true) && valid_bearer_token?)
  end

  def render_guest_search_throttled
    response.set_header("Retry-After", PERIOD.to_i.to_s)
    if request.format.json? || request.headers["Accept"].to_s.include?("json")
      render json: { error: "rate_limited", role: "guest" }, status: :too_many_requests
    else
      render "shared/guest_search_throttled", status: :too_many_requests, formats: :html, layout: "application"
    end
  end
end
