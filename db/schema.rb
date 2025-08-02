# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_08_02_103116) do
  create_table "action_mcp_session_messages", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "session_id", null: false
    t.string "direction", default: "client", null: false, comment: "The message recipient"
    t.string "message_type", null: false, comment: "The type of the message"
    t.string "jsonrpc_id"
    t.text "message_json", size: :long, collation: "utf8mb4_bin", comment: "Stores the raw message payload as text"
    t.boolean "is_ping", default: false, null: false, comment: "Whether the message is a ping"
    t.boolean "request_acknowledged", default: false, null: false
    t.boolean "request_cancelled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_action_mcp_session_messages_on_session_id"
  end

  create_table "action_mcp_session_resources", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "session_id", null: false
    t.string "uri", null: false
    t.string "name"
    t.text "description"
    t.string "mime_type", null: false
    t.boolean "created_by_tool", default: false
    t.datetime "last_accessed_at"
    t.text "metadata", size: :long, collation: "utf8mb4_bin", comment: "Stores resource metadata as text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_action_mcp_session_resources_on_session_id"
  end

  create_table "action_mcp_session_subscriptions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "session_id", null: false
    t.string "uri", null: false
    t.datetime "last_notification_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_action_mcp_session_subscriptions_on_session_id"
  end

  create_table "action_mcp_sessions", id: :string, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "role", default: "server", null: false, comment: "The role of the session"
    t.string "status", default: "pre_initialize", null: false
    t.datetime "ended_at", comment: "The time the session ended"
    t.string "protocol_version"
    t.text "server_capabilities", collation: "utf8mb4_bin", comment: "The capabilities of the server (stored as text to avoid JSON validation issues)"
    t.text "client_capabilities", size: :long, collation: "utf8mb4_bin", comment: "The capabilities of the client"
    t.text "server_info", collation: "utf8mb4_bin", comment: "The information about the server (stored as text to avoid JSON validation issues)"
    t.text "client_info", size: :long, collation: "utf8mb4_bin", comment: "The information about the client"
    t.boolean "initialized", default: false, null: false
    t.integer "messages_count", default: 0, null: false
    t.integer "sse_event_counter", default: 0, null: false
    t.text "tool_registry", size: :long, default: "[]", collation: "utf8mb4_bin", comment: "Tool registry as text"
    t.text "prompt_registry", size: :long, default: "[]", collation: "utf8mb4_bin", comment: "Prompt registry as text"
    t.text "resource_registry", size: :long, default: "[]", collation: "utf8mb4_bin", comment: "Resource registry as text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "action_mcp_sse_events", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "session_id", null: false
    t.integer "event_id", null: false
    t.text "data", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_action_mcp_sse_events_on_created_at"
    t.index ["session_id", "event_id"], name: "index_action_mcp_sse_events_on_session_id_and_event_id", unique: true
    t.index ["session_id"], name: "index_action_mcp_sse_events_on_session_id"
  end

  create_table "memory_entities", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "name"
    t.string "entity_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "memory_observations_count"
    t.text "aliases"
    t.index ["entity_type"], name: "index_memory_entities_on_entity_type"
    t.index ["name"], name: "index_memory_entities_on_name", unique: true
  end

  create_table "memory_observations", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.text "content"
    t.bigint "memory_entity_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["memory_entity_id"], name: "index_memory_observations_on_memory_entity_id"
  end

  create_table "memory_relations", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "from_entity_id", null: false
    t.bigint "to_entity_id", null: false
    t.string "relation_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_entity_id", "to_entity_id", "relation_type"], name: "index_memory_relations_uniqueness", unique: true
    t.index ["from_entity_id"], name: "index_memory_relations_on_from_entity_id"
    t.index ["relation_type"], name: "index_memory_relations_on_relation_type"
    t.index ["to_entity_id"], name: "index_memory_relations_on_to_entity_id"
  end

  add_foreign_key "action_mcp_session_messages", "action_mcp_sessions", column: "session_id", name: "fk_action_mcp_session_messages_session_id", on_update: :cascade, on_delete: :cascade
  add_foreign_key "action_mcp_session_resources", "action_mcp_sessions", column: "session_id", on_delete: :cascade
  add_foreign_key "action_mcp_session_subscriptions", "action_mcp_sessions", column: "session_id", on_delete: :cascade
  add_foreign_key "action_mcp_sse_events", "action_mcp_sessions", column: "session_id"
  add_foreign_key "memory_observations", "memory_entities"
  add_foreign_key "memory_relations", "memory_entities", column: "from_entity_id"
  add_foreign_key "memory_relations", "memory_entities", column: "to_entity_id"
end
