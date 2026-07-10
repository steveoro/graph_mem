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
  end
end
