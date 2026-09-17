# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP messages endpoint", type: :request do
  after { AgentContext.delete_all }

  describe "POST /mcp/messages" do
    it "records client activity using the X-MCP-Client header from HTTP requests" do
      host! "localhost"

      post "/mcp/messages",
        params: {
          jsonrpc: "2.0",
          method: "tools/call",
          params: {
            name: "get_version",
            arguments: {}
          },
          id: 1
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "X-MCP-Client" => "cursor-http"
        }

      expect(response).to have_http_status(:ok)
      expect(AgentContext.find_by!(client_id: "cursor-http").last_tool_name).to eq("get_version")
      expect(AgentContext.find_by(client_id: GraphMemContext::DEFAULT_CLIENT_ID)).to be_nil
    end

    it "uses the default profile and does not call hidden maintenance tools" do
      host! "localhost"

      post "/mcp/messages",
        params: {
          jsonrpc: "2.0",
          method: "tools/call",
          params: {
            name: "dream_state_status",
            arguments: {}
          },
          id: 2
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "X-MCP-Client" => "legacy-hidden-maintenance"
        }

      expect(response).to have_http_status(:ok)
      expect(AgentContext.find_by(client_id: "legacy-hidden-maintenance")).to be_nil
    end

    it "keeps list-hidden compatibility aliases callable" do
      host! "localhost"

      post "/mcp/messages",
        params: {
          jsonrpc: "2.0",
          method: "tools/call",
          params: {
            name: "search_entities",
            arguments: { query: "legacy-alias-probe" }
          },
          id: 3
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "X-MCP-Client" => "legacy-hidden-alias"
        }

      expect(response).to have_http_status(:ok)
      expect(AgentContext.find_by!(client_id: "legacy-hidden-alias").last_tool_name).to eq("search_entities")
    end

    it "keeps hidden mutation adapters callable" do
      entity = MemoryEntity.create!(name: "Legacy mutation adapter", entity_type: "Task")
      host! "localhost"

      post "/mcp/messages",
        params: {
          jsonrpc: "2.0",
          method: "tools/call",
          params: {
            name: "update_entity",
            arguments: { entity_id: entity.id, description: "Legacy updated" }
          },
          id: 4
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "X-MCP-Client" => "legacy-hidden-mutation"
        }

      expect(response).to have_http_status(:ok)
      expect(entity.reload.description).to eq("Legacy updated")
    end
  end
end
