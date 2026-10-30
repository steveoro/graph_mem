# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :actor
  # What an MCP client says about itself (ActorClaim.transport); nil for the web UI and REST.
  attribute :actor_claim
  attribute :deletion_reason
  # The open ChangeSet::Context (UI-4a), set by ChangeSet.record.
  attribute :change_set
end
