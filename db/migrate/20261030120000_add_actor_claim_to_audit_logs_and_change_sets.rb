# frozen_string_literal: true

# Audit actor (1.65.0): what an MCP client and its model say about themselves (X-MCP-Client, the
# MCP clientInfo, the `source` prefix), next to the server-side `actor`. Display only: nothing
# authorizes, credits or filters on it, so it has no index.
class AddActorClaimToAuditLogsAndChangeSets < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :actor_claim, :string, limit: 255
    add_column :change_sets, :actor_claim, :string, limit: 255
  end
end
