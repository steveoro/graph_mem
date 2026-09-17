# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MCP Streamable HTTP endpoint", type: :request do
  after { AgentContext.delete_all }

  def initialize_session(path)
    host! "localhost"
    post path,
      params: {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "profile-rspec", version: "1.0.0" }
        }
      }.to_json,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_ACCEPT" => "application/json"
      }
    expect(response).to have_http_status(:ok)
    response.headers["Mcp-Session-Id"]
  end

  def post_rpc(path, session_id, method, params: nil, id: 2)
    payload = { jsonrpc: "2.0", id: id, method: method }
    payload[:params] = params if params
    post path,
      params: payload.to_json,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "HTTP_ACCEPT" => "application/json",
        "Mcp-Session-Id" => session_id
      }
  end

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
          "HTTP_ORIGIN" => "http://localhost:3001",
          "X-MCP-Client" => "streamable-test"
        }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/json")
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Access-Control-Expose-Headers"]).to include("Mcp-Session-Id")
      expect(response.headers["Mcp-Session-Id"]).to be_present

      body = response.parsed_body
      expect(body["result"]["protocolVersion"]).to eq("2025-03-26")
      expect(body["result"]["serverInfo"]["name"]).to eq("graph-mem")
      expect(body.dig("result", "capabilities", "prompts")).to eq("listChanged" => false)
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
      tools = response.parsed_body["result"]["tools"]
      expect(tools.size).to eq(12)
      expect(tools.map { |tool| tool["name"] }).to include(
        "search",
        "get_entities",
        "graph_write",
        "graph_edit",
        "graph_delete"
      )
      expect(tools.map { |tool| tool["name"] }).not_to include(
        "dream_state_status",
        "search_entities",
        "get_entity",
        "find_relations",
        "create_entity",
        "update_entity",
        "delete_entity",
        "get_version",
        "clear_context"
      )
      expect(tools).to all(include("outputSchema"))

      search_tool = tools.find { |tool| tool["name"] == "search" }
      expect(search_tool["annotations"]).to eq(
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      )
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

    it "returns a structured JSON error envelope for a missing entity" do
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
          id: 3,
          method: "tools/call",
          params: {
            name: "get_entity",
            arguments: { entity_id: 9_999_999 }
          }
        }.to_json,
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "Mcp-Session-Id" => session_id
        }

      expect(response).to have_http_status(:ok)
      result = response.parsed_body["result"]
      expect(result["isError"]).to eq(true)
      expect(result).not_to have_key("structuredContent")
      text = result["content"].first["text"]
      expect(text).not_to include("Error:")
      expect(text).not_to include("app/tools")
      payload = JSON.parse(text)
      expect(payload).to include(
        "error" => true,
        "category" => "not_found",
        "retriable" => false,
        "tool" => "get_entity"
      )
      expect(payload["message"]).to match(/not found/i)
      expect(payload["next_move"]).to include("search")
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

    it "includes CORS headers on JSON error responses" do
      host! "localhost"

      post "/mcp",
        params: "{not-json",
        headers: {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ACCEPT" => "application/json",
          "HTTP_ORIGIN" => "http://localhost:3001"
        }

      expect(response).to have_http_status(:bad_request)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Access-Control-Expose-Headers"]).to include("Mcp-Session-Id")
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

  describe "connection profiles" do
    it "advertises the expected catalog for each profile" do
      {
        "/mcp" => [ 12, false ],
        "/mcp/readonly" => [ 9, false ],
        "/mcp/maintenance" => [ 22, true ]
      }.each do |path, (expected_count, includes_maintenance)|
        session_id = initialize_session(path)
        post_rpc(path, session_id, "tools/list")

        names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
        expect(names.size).to eq(expected_count)
        expect(names.include?("dream_state_status")).to eq(includes_maintenance)
      end
    end

    it "keeps hidden compatibility aliases callable" do
      session_id = initialize_session("/mcp")
      post_rpc(
        "/mcp",
        session_id,
        "tools/call",
        params: { name: "search_entities", arguments: { query: "no-match-compatibility-probe" } }
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("error")
      expect(response.parsed_body.dig("result", "isError")).to be(false)
    end

    it "keeps hidden mutation adapters callable" do
      entity = MemoryEntity.create!(name: "Hidden mutation adapter", entity_type: "Task")
      session_id = initialize_session("/mcp")
      post_rpc(
        "/mcp",
        session_id,
        "tools/call",
        params: {
          name: "update_entity",
          arguments: { entity_id: entity.id, description: "Updated through alias" }
        }
      )

      expect(response.parsed_body.dig("result", "isError")).to be(false)
      expect(entity.reload.description).to eq("Updated through alias")
    end

    it "rejects tools hidden from the selected profile" do
      default_session = initialize_session("/mcp")
      post_rpc(
        "/mcp",
        default_session,
        "tools/call",
        params: { name: "dream_state_status", arguments: {} }
      )

      expect(response.parsed_body.dig("error", "message")).to include("Tool not found")

      readonly_session = initialize_session("/mcp/readonly")
      post_rpc(
        "/mcp/readonly",
        readonly_session,
        "tools/call",
        params: { name: "create_entity", arguments: { name: "Hidden", entity_type: "Project" } }
      )

      expect(response.parsed_body.dig("error", "message")).to include("Tool not found")
    end

    it "allows the maintenance profile to call a maintenance tool" do
      session_id = initialize_session("/mcp/maintenance")
      post_rpc(
        "/mcp/maintenance",
        session_id,
        "tools/call",
        params: { name: "dream_state_status", arguments: {} }
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("result", "isError")).not_to be(true)
      expect(response.parsed_body["result"]).not_to have_key("structuredContent")
    end

    it "selects tools from each request path even when a session id is reused" do
      session_id = initialize_session("/mcp")

      post_rpc("/mcp", session_id, "tools/list")
      expect(response.parsed_body.dig("result", "tools").size).to eq(12)

      post_rpc("/mcp/maintenance", session_id, "tools/list", id: 3)
      expect(response.parsed_body.dig("result", "tools").size).to eq(22)
    end

    it "supports deleting a session through a profile path" do
      session_id = initialize_session("/mcp/readonly")

      delete "/mcp/readonly", headers: { "Mcp-Session-Id" => session_id }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "workflow prompts" do
    it "lists and renders native prompts" do
      session_id = initialize_session("/mcp")
      post_rpc("/mcp", session_id, "prompts/list")

      prompts = response.parsed_body.dig("result", "prompts")
      expect(prompts.pluck("name")).to contain_exactly("orient", "recall", "persist")
      recall = prompts.find { |prompt| prompt["name"] == "recall" }
      expect(recall["arguments"]).to include(
        "name" => "topic",
        "description" => "Keywords or subject to recall",
        "required" => true
      )

      post_rpc(
        "/mcp",
        session_id,
        "prompts/get",
        params: { name: "recall", arguments: { topic: "GraphMem" } },
        id: 10
      )

      text = response.parsed_body.dig("result", "messages", 0, "content", "text")
      expect(text).to include("GraphMem", "search", "get_entities")
    end
  end

  describe "success workflow metadata" do
    it "adds version, next_move, context banner, and MCP _meta" do
      session_id = initialize_session("/mcp")
      post_rpc(
        "/mcp",
        session_id,
        "tools/call",
        params: { name: "get_current_time", arguments: {} }
      )

      result = response.parsed_body["result"]
      text = result.dig("content", 0, "text")
      expect(JSON.parse(text)).to eq(result["structuredContent"])
      expect(result["structuredContent"]).to include(
        "version" => GraphMem::VERSION,
        "next_move" => include("timestamp"),
        "context" => include("status" => "none")
      )
      expect(result["_meta"]).to eq(
        "graphMemVersion" => GraphMem::VERSION,
        "contextStatus" => "none"
      )
    end
  end

  describe "OPTIONS /mcp" do
    it "responds to CORS preflight" do
      host! "localhost"

      options "/mcp",
        headers: {
          "HTTP_ORIGIN" => "http://localhost:3001",
          "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "DELETE",
          "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "content-type,mcp-session-id,x-mcp-client"
        }

      expect(response).to have_http_status(:ok)
      expect(response.headers["access-control-allow-methods"]).to include("POST")
      expect(response.headers["access-control-allow-methods"]).to include("DELETE")
      expect(response.headers["access-control-allow-headers"]).to match(/content-type.*mcp-session-id.*x-mcp-client/i)
      expect(response.headers["access-control-expose-headers"]).to include("Mcp-Session-Id")
    end

    it "answers preflight on each explicit profile path" do
      host! "localhost"

      %w[/mcp/readonly /mcp/maintenance].each do |path|
        options path,
          headers: {
            "HTTP_ORIGIN" => "http://localhost:3001",
            "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST"
          }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
