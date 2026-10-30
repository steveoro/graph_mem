# frozen_string_literal: true

require "rails_helper"

# Audit actor (1.65.0): a write over /mcp records actor mcp:<tool>, the claim (X-MCP-Client,
# the session's clientInfo, the source's who) and the reason (the source's why), on its audit
# rows and its change set. Synthetic data only.
RSpec.describe "MCP writes record who made them", type: :request do
  def request_headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream",
                          "HTTP_X_MCP_CLIENT" => "synth-client-a" }

  before do
    host! "localhost"
    GraphMem::OfficialMcp.reset!
  end

  after do
    GraphMem::OfficialMcp.reset!
    AgentContext.delete_all
  end

  def initialize_session
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize",
                           params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "synth-agent", version: "0.0.1" } } }.to_json,
                 headers: request_headers
    response.headers["Mcp-Session-Id"]
  end

  def tool_call(session_id, name, arguments, id: 2)
    post "/mcp", params: { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: name, arguments: arguments } }.to_json,
                 headers: request_headers.merge("Mcp-Session-Id" => session_id)
    response.parsed_body
  end

  it "records actor, claim and reason for a graph_write, on the audit rows and the change set" do
    session_id = initialize_session
    entity = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")

    body = tool_call(session_id, "graph_write", { operations: [ { type: "create_observation", entity_id: entity.id,
                                                                  text_content: "SynthWidget renders synthetic tiles.",
                                                                  source: "synth-agent/model-x: synthetic task" } ] })

    expect(body.dig("result", "isError")).to be(false)
    observation = MemoryObservation.find_by!(content: "SynthWidget renders synthetic tiles.")
    row = AuditLog.find_by!(auditable_type: "MemoryObservation", auditable_id: observation.id, action: "create")
    expect(row).to have_attributes(actor: "mcp:graph_write", reason: "synthetic task",
                                   actor_claim: "client=synth-client-a · synth-agent/0.0.1 · synth-agent/model-x")
    expect(row.change_set).to have_attributes(kind: "graph.write", actor: "mcp:graph_write",
                                              actor_claim: "client=synth-client-a · synth-agent/0.0.1")
  end

  it "gives each call its own actor, and leaves nothing behind between calls" do
    session_id = initialize_session
    entity = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")

    tool_call(session_id, "graph_write", { operations: [ { type: "create_observation", entity_id: entity.id, text_content: "Alpha Service is synthetic." } ] })
    tool_call(session_id, "graph_edit", { operations: [ { type: "update_entity", entity_id: entity.id, description: "A synthetic service." } ] }, id: 3)

    expect(AuditLog.where(auditable_type: "MemoryEntity", auditable_id: entity.id, action: "update").sole.actor).to eq("mcp:graph_edit")
    expect(ChangeSet.order(:id).pluck(:kind, :actor)).to eq([ [ "graph.write", "mcp:graph_write" ], [ "graph.edit", "mcp:graph_edit" ] ])
    expect([ Current.actor, Current.actor_claim ]).to eq([ nil, nil ])
  end
end
