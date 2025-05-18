class RemoveJsonCheckConstraintFromSessionMessages < ActiveRecord::Migration[8.0]
  def up
    if table_exists?(:action_mcp_session_messages)
      # Ensure the message_json column is TEXT to allow non-standard JSON strings
      if column_exists?(:action_mcp_session_messages, :message_json)
        change_column :action_mcp_session_messages, :message_json, :text, size: :long, collation: "utf8mb4_bin", comment: "Stores the raw message payload as text"
        Rails.logger.info "Changed action_mcp_session_messages.message_json to TEXT."
      end

      # Attempt to remove any explicit check constraint by its Rails name
      # This might be redundant if changing to TEXT already removed implicit validation,
      # but serves as a cleanup.
      begin
        remove_check_constraint :action_mcp_session_messages, name: "message_json"
        Rails.logger.info "Successfully removed check constraint 'message_json' from 'action_mcp_session_messages' (if it existed by that name)."
      rescue ArgumentError => e
        Rails.logger.warn "Could not remove check constraint 'message_json' from 'action_mcp_session_messages'. It might not exist or name is incorrect. Error: #{e.message}"
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn "Could not remove check constraint 'message_json' from 'action_mcp_session_messages' due to a database error (it might not exist). Error: #{e.message}"
      end
    end
  end

  def down
    # Reverting to JSON type as it was before this migration's 'up' method.
    # This assumes the 'ConsolidatedMigration' would have set it to :json.
    if table_exists?(:action_mcp_session_messages)
      if column_exists?(:action_mcp_session_messages, :message_json)
        change_column :action_mcp_session_messages, :message_json, :json
        Rails.logger.info "Reverted action_mcp_session_messages.message_json to JSON type."
        # Optionally, re-add the check constraint if it was specific and known
        # add_check_constraint :action_mcp_session_messages, "json_valid(`message_json`)", name: "message_json"
      end
    end
  end
end
