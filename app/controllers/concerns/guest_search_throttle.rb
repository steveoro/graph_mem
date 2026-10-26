# frozen_string_literal: true

# Caps how often a read-only guest can search (UI-1b): a vector query costs an embedding
# call, and the guest password may be shared. Operators and bearer-token clients aren't
# limited. One budget per IP covers every throttled action (HTML and API).
#
# Usage:
#   class SearchController < ApplicationController
#     include GuestSearchThrottle
#     throttle_guest_search :results
#   end
module GuestSearchThrottle
  extend ActiveSupport::Concern

  LIMIT = 60
  PERIOD = 1.minute

  class_methods do
    # @param actions [Array<Symbol>] the search actions to throttle for guests
    def throttle_guest_search(*actions)
      rate_limit to: LIMIT, within: PERIOD, only: actions, scope: "guest-search",
                 if: :guest_search_throttled?, with: -> { render_guest_search_throttled }
    end
  end

  private

  # A guest session, unless the request also carries a valid bearer token (API only).
  def guest_search_throttled?
    guest_signed_in? && !(respond_to?(:valid_bearer_token?, true) && valid_bearer_token?)
  end

  def render_guest_search_throttled
    if request.format.json? || request.headers["Accept"].to_s.include?("json")
      render json: { error: "rate_limited", role: "guest" }, status: :too_many_requests
    else
      render "shared/guest_search_throttled", status: :too_many_requests, formats: :html, layout: "application"
    end
  end
end
