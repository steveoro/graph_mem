# frozen_string_literal: true

class DropActionMcpTables < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :action_mcp_session_messages, :action_mcp_sessions,
                       column: :session_id, if_exists: true
    remove_foreign_key :action_mcp_session_resources, :action_mcp_sessions,
                       column: :session_id, if_exists: true
    remove_foreign_key :action_mcp_session_subscriptions, :action_mcp_sessions,
                       column: :session_id, if_exists: true
    remove_foreign_key :action_mcp_sse_events, :action_mcp_sessions,
                       column: :session_id, if_exists: true

    drop_table :action_mcp_session_messages, if_exists: true
    drop_table :action_mcp_session_resources, if_exists: true
    drop_table :action_mcp_session_subscriptions, if_exists: true
    drop_table :action_mcp_sse_events, if_exists: true
    drop_table :action_mcp_sessions, if_exists: true
  end

  def down
    create_table "action_mcp_sessions", id: :string, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
      t.string "role", default: "server", null: false, comment: "The role of the session"
      t.string "status", default: "pre_initialize", null: false
      t.datetime "ended_at", comment: "The time the session ended"
      t.string "protocol_version"
      t.text "server_capabilities", collation: "utf8mb4_bin"
      t.text "client_capabilities", size: :long, collation: "utf8mb4_bin"
      t.text "server_info", collation: "utf8mb4_bin"
      t.text "client_info", size: :long, collation: "utf8mb4_bin"
      t.boolean "initialized", default: false, null: false
      t.integer "messages_count", default: 0, null: false
      t.integer "sse_event_counter", default: 0, null: false
      t.text "tool_registry", size: :long, default: "[]", collation: "utf8mb4_bin"
      t.text "prompt_registry", size: :long, default: "[]", collation: "utf8mb4_bin"
      t.text "resource_registry", size: :long, default: "[]", collation: "utf8mb4_bin"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "action_mcp_session_messages", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
      t.string "session_id", null: false
      t.string "direction", default: "client", null: false
      t.string "message_type", null: false
      t.string "jsonrpc_id"
      t.text "message_json", size: :long, collation: "utf8mb4_bin"
      t.boolean "is_ping", default: false, null: false
      t.boolean "request_acknowledged", default: false, null: false
      t.boolean "request_cancelled", default: false, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index [ "session_id" ], name: "index_action_mcp_session_messages_on_session_id"
    end

    create_table "action_mcp_session_resources", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
      t.string "session_id", null: false
      t.string "uri", null: false
      t.string "name"
      t.text "description"
      t.string "mime_type", null: false
      t.boolean "created_by_tool", default: false
      t.datetime "last_accessed_at"
      t.text "metadata", size: :long, collation: "utf8mb4_bin"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index [ "session_id" ], name: "index_action_mcp_session_resources_on_session_id"
    end

    create_table "action_mcp_session_subscriptions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
      t.string "session_id", null: false
      t.string "uri", null: false
      t.datetime "last_notification_at"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index [ "session_id" ], name: "index_action_mcp_session_subscriptions_on_session_id"
    end

    create_table "action_mcp_sse_events", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
      t.string "session_id", null: false
      t.integer "event_id", null: false
      t.text "data", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index [ "created_at" ], name: "index_action_mcp_sse_events_on_created_at"
      t.index [ "session_id", "event_id" ], name: "index_action_mcp_sse_events_on_session_id_and_event_id", unique: true
      t.index [ "session_id" ], name: "index_action_mcp_sse_events_on_session_id"
    end

    add_foreign_key "action_mcp_session_messages", "action_mcp_sessions", column: "session_id", name: "fk_action_mcp_session_messages_session_id", on_update: :cascade, on_delete: :cascade
    add_foreign_key "action_mcp_session_resources", "action_mcp_sessions", column: "session_id", on_delete: :cascade
    add_foreign_key "action_mcp_session_subscriptions", "action_mcp_sessions", column: "session_id", on_delete: :cascade
    add_foreign_key "action_mcp_sse_events", "action_mcp_sessions", column: "session_id"
  end
end
