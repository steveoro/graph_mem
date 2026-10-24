# frozen_string_literal: true

# Skeleton for role-based access control (UI-1 wires up the guest role).
#
# Usage (UI-1+):
#   class SearchController < ApplicationController
#     allow_guest :index, :results
#   end
#
# In UI-0, nothing opts in — all authenticated routes require operator.
module RoleAuthorization
  extend ActiveSupport::Concern

  included do
    class_attribute :_guest_allowed_actions, default: []
  end

  class_methods do
    # Declare that guests may access these actions (UI-1+). Repeated calls, and calls in a
    # subclass, add to the inherited list; a new array is assigned, so the parent is untouched.
    #
    # @param actions [Array<Symbol, String>] action names
    # @return [Array<String>] every guest-allowed action of this class
    def allow_guest(*actions)
      self._guest_allowed_actions = (_guest_allowed_actions + actions.map(&:to_s)).uniq
    end
  end
end
