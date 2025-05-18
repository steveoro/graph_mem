class ChangeActionMCPSessionCapabilitiesToJsonText < ActiveRecord::Migration[8.0]
  def change
    if table_exists?(:action_mcp_sessions)
      if column_exists?(:action_mcp_sessions, :server_capabilities)
        change_column :action_mcp_sessions, :server_capabilities, :text, comment: 'The capabilities of the server (stored as text to avoid JSON validation issues)'
      end

      if column_exists?(:action_mcp_sessions, :server_info)
        change_column :action_mcp_sessions, :server_info, :text, comment: 'The information about the server (stored as text to avoid JSON validation issues)'
      end
    end
  end
end
