class RemoveRemainingJsonCheckConstraints < ActiveRecord::Migration[8.0]
  def up
    # For action_mcp_session_resources
    if table_exists?(:action_mcp_session_resources)
      if column_exists?(:action_mcp_session_resources, :metadata)
        change_column :action_mcp_session_resources, :metadata, :text, size: :long, collation: "utf8mb4_bin", comment: "Stores resource metadata as text"
        Rails.logger.info "Changed action_mcp_session_resources.metadata to TEXT."
      end
      begin
        remove_check_constraint :action_mcp_session_resources, name: "metadata"
        Rails.logger.info "Successfully removed check constraint 'metadata' from 'action_mcp_session_resources'."
      rescue ArgumentError => e
        Rails.logger.warn "Could not remove check constraint 'metadata' from 'action_mcp_session_resources'. It might not exist or name is incorrect. Error: #{e.message}"
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn "Could not remove check constraint 'metadata' from 'action_mcp_session_resources' due to a database error (it might not exist). Error: #{e.message}"
      end
    else
      Rails.logger.warn "Table 'action_mcp_session_resources' does not exist, skipping."
    end

    # For action_mcp_sessions
    sessions_columns_and_constraints = {
      client_capabilities: { comment: "The capabilities of the client" },
      client_info:         { comment: "The information about the client" },
      tool_registry:       { comment: "Tool registry as text", default: "[]" },
      prompt_registry:     { comment: "Prompt registry as text", default: "[]" },
      resource_registry:   { comment: "Resource registry as text", default: "[]" }
    }

    if table_exists?(:action_mcp_sessions)
      sessions_columns_and_constraints.each do |column_name, options|
        if column_exists?(:action_mcp_sessions, column_name)
          change_column :action_mcp_sessions, column_name, :text, size: :long, collation: "utf8mb4_bin", comment: options[:comment], default: options[:default]
          Rails.logger.info "Changed action_mcp_sessions.#{column_name} to TEXT."
        end
        begin
          # Use column_name as constraint name as per schema.rb pattern
          remove_check_constraint :action_mcp_sessions, name: column_name.to_s
          Rails.logger.info "Successfully removed check constraint '#{column_name}' from 'action_mcp_sessions'."
        rescue ArgumentError => e
          Rails.logger.warn "Could not remove check constraint '#{column_name}' from 'action_mcp_sessions'. It might not exist or name is incorrect. Error: #{e.message}"
        rescue ActiveRecord::StatementInvalid => e
          Rails.logger.warn "Could not remove check constraint '#{column_name}' from 'action_mcp_sessions' due to a database error (it might not exist). Error: #{e.message}"
        end
      end
    else
      Rails.logger.warn "Table 'action_mcp_sessions' does not exist, skipping."
    end
  end

  def down
    Rails.logger.info "Check constraints and column type changes in this migration were not fully reversed on rollback for simplicity."
  end
end
