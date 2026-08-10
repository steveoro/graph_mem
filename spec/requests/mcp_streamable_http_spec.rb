# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP Streamable HTTP endpoint", type: :request do
  after { AgentContext.delete_all }

  describe "POST /mcp" do
    it "initializes a 2025-03-26 session and returns a Mcp-Session-Id header" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "X-MCP-Client" => "streamable-test"
        }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/json")
      expect(response.headers["Mcp-Session-Id"]).to be_present

      body = response.parsed_body
      expect(body["result"]["protocolVersion"]).to eq("2025-03-26")
      expect(body["result"]["serverInfo"]["name"]).to eq("graph-mem")
    end

    it "negotiates 2024-11-05 for older clients" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2024-11-05",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]["protocolVersion"]).to eq("2024-11-05")
    end

    it "lists tools for an initialized session" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      session_id = response.headers["Mcp-Session-Id"]

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/list"
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => session_id
        }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Mcp-Session-Id"]).to eq(session_id)
      expect(response.parsed_body["result"]["tools"]).to be_an(Array)
      expect(response.parsed_body["result"]["tools"].map { |t| t["name"] }).to include("get_version")
    end

    it "calls a tool and preserves the X-MCP-Client context" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      session_id = response.headers["Mcp-Session-Id"]

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: {
            name: "get_version",
            arguments: {}
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => session_id,
          "X-MCP-Client" => "streamable-test-client"
        }

      expect(response).to have_http_status(:ok)
      expect(AgentContext.find_by(client_id: "streamable-test-client")).to be_present
    end

    it "falls back to the default client id when X-MCP-Client is absent" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      session_id = response.headers["Mcp-Session-Id"]

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: {
            name: "get_version",
            arguments: {}
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => session_id
        }

      expect(response).to have_http_status(:ok)
      expect(AgentContext.find_by(client_id: GraphMemContext::DEFAULT_CLIENT_ID)).to be_present
    end

    it "rejects non-initialize requests without a session id" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list"
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]["message"]).to match(/missing.*Mcp-Session-Id/i)
    end

    it "returns 404 for an unknown session id" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list"
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => "not-a-real-session"
        }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /mcp" do
    it "terminates an active session" do
      host! "localhost"

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "rspec", version: "1.0.0" }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json"
        }

      session_id = response.headers["Mcp-Session-Id"]

      delete "/mcp",
        headers: {
          "Mcp-Session-Id" => session_id
        }

      expect(response).to have_http_status(:ok)

      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/list"
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => session_id
        }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "OPTIONS /mcp" do
    it "responds to CORS preflight" do
      host! "localhost"

      options "/mcp"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Methods"]).to include("POST")
      expect(response.headers["Access-Control-Allow-Methods"]).to include("DELETE")
      expect(response.headers["Access-Control-Allow-Headers"]).to include("Mcp-Session-Id")
    end
  end
end
