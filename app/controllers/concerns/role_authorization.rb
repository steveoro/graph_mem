# frozen_string_literal: true

# Role-based access for the HTML controllers (UI-1). Deny by default: a guest may run an
# action only when its controller opts in with `allow_guest`; everything else is
# operator-only and answers a guest with 403. The JSON API has its own allowlist
# (ApiAuthentication::GUEST_READ_ACTIONS).
#
# Usage:
#   class SearchController < ApplicationController
#     allow_guest :results
#   end
module RoleAuthorization
  extend ActiveSupport::Concern

  included do
    class_attribute :_guest_allowed_actions, default: []
  end

  class_methods do
    # Declare that guests may access these actions. Repeated calls, and calls in a
    # subclass, add to the inherited list; a new array is assigned, so the parent is untouched.
    #
    # @param actions [Array<Symbol, String>] action names
    # @return [Array<String>] every guest-allowed action of this class
    def allow_guest(*actions)
      self._guest_allowed_actions = (_guest_allowed_actions + actions.map(&:to_s)).uniq
    end
  end

  private

  # before_action: lets operators through, and guests only into opted-in actions.
  def authorize_role!
    return unless guest_signed_in?
    return if self.class._guest_allowed_actions.include?(action_name)

    render_guest_forbidden
  end

  def render_guest_forbidden
    if request.format.json? || request.headers["Accept"].to_s.include?("json")
      render json: { error: "forbidden", role: "guest" }, status: :forbidden
    else
      render "shared/forbidden", status: :forbidden, formats: :html, layout: "application"
    end
  end
end
