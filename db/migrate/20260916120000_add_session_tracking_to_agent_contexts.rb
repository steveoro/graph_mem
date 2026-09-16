# frozen_string_literal: true

# Lets GraphMem notice when two concurrent agents share one X-MCP-Client id and
# are therefore silently overwriting each other's active project context.
class AddSessionTrackingToAgentContexts < ActiveRecord::Migration[8.1]
  def change
    # When the project context was last changed, as opposed to last_seen_at,
    # which any tool call bumps.
    add_column :agent_contexts, :context_set_at, :datetime

    # Mcp-Session-Id of the most recent caller. Only available on the Streamable
    # HTTP endpoint; the legacy /mcp/sse endpoint has no per-connection id.
    add_column :agent_contexts, :last_session_id, :string
  end
end
