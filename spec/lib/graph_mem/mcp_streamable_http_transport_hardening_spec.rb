# frozen_string_literal: true

require "rails_helper"

# mcp plan PR-2 §2.2-§2.4, §2.9, §2.19: Streamable HTTP hardening, driven through Rack.
RSpec.describe GraphMem::McpStreamableHttpTransport, "hardening" do
  let(:server) { FastMcp.server }
  let(:options) { {} }
  let(:transport) do
    described_class.new(->(_env) { [ 404, {}, [] ] }, server,
                        { allowed_origins: [ "localhost", "127.0.0.1" ], localhost_only: false,
                          logger: Logger.new(nil) }.merge(options))
  end

  around do |example|
    original = server.transport
    example.run
  ensure
    transport.stop
    server.transport = original
  end

  def rack(method, body: nil, session_id: nil, headers: {}, path: "/mcp")
    env = Rack::MockRequest.env_for(
      path, method: method, input: body.is_a?(String) || body.nil? ? body.to_s : JSON.generate(body),
            "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream",
            "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost"
    )
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    headers.each { |key, value| env[key] = value }
    status, response_headers, response_body = transport.call(env)
    [ status, response_headers, response_body.join ]
  end

  def json(body) = JSON.parse(body)

  def initialize_session(version = "2025-11-25")
    status, headers, body = rack("POST", body: { jsonrpc: "2.0", id: 1, method: "initialize",
                                                 params: { protocolVersion: version, capabilities: {},
                                                           clientInfo: { name: "SynthWidget", version: "1" } } })
    [ status, headers["Mcp-Session-Id"], json(body) ]
  end

  # Opens a server-to-client SSE stream on a hijacked StringIO; returns the Rack status (-1 = hijacked).
  def open_get_stream(session_id)
    env = Rack::MockRequest.env_for("/mcp", method: "GET", "HTTP_ACCEPT" => "text/event-stream",
                                            "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost")
    env["HTTP_MCP_SESSION_ID"] = session_id
    env["rack.hijack"] = -> { }
    env["rack.hijack_io"] = StringIO.new
    transport.call(env).first
  end

  def rpc(session_id, method, id: 2, params: nil, headers: {})
    payload = { jsonrpc: "2.0", id: id, method: method }
    payload[:params] = params if params
    rack("POST", body: payload, session_id: session_id, headers: headers)
  end

  describe "body size (§2.3)" do
    let(:options) { { max_request_bytes: 1_000 } }

    it "returns 413 for an oversized POST and creates no session" do
      status, = rack("POST", body: { jsonrpc: "2.0", id: 1, method: "initialize", params: { pad: "x" * 5_000 } })

      expect(status).to eq(413)
      expect(transport.sessions).to be_empty
    end
  end

  describe "handshake negotiation (§2.2)" do
    { "2026-07-28" => "2025-11-25", "2025-11-25" => "2025-11-25", "2025-06-18" => "2025-06-18",
      "2025-03-26" => "2025-03-26", "2024-11-05" => "2024-11-05", "9" => "2025-11-25" }.each do |asked, answered|
      it "negotiates #{answered} when initialize asks for #{asked}" do
        status, _id, body = initialize_session(asked)

        expect(status).to eq(200)
        expect(body.dig("result", "protocolVersion")).to eq(answered)
      end
    end

    it "serves in-session requests with no MCP-Protocol-Version or any supported one" do
      _status, session_id, = initialize_session

      expect(rpc(session_id, "ping").first).to eq(200)
      expect(rpc(session_id, "ping", headers: { "HTTP_MCP_PROTOCOL_VERSION" => "2024-11-05" }).first).to eq(200)
    end

    %w[1999-01-01 2026-07-28].each do |header|
      it "answers MCP-Protocol-Version #{header} with 400 -32000 listing the supported versions" do
        _status, session_id, = initialize_session
        status, _headers, body = rpc(session_id, "ping", id: 7, headers: { "HTTP_MCP_PROTOCOL_VERSION" => header })

        expect(status).to eq(400)
        expect(json(body)).to include("id" => 7, "error" => include("code" => -32_000))
        expect(json(body).dig("error", "message")).to include(header, "2025-11-25", "2024-11-05")
      end
    end

    it "checks the session first: unknown session plus a bad header is 404" do
      status, = rpc("nope", "ping", headers: { "HTTP_MCP_PROTOCOL_VERSION" => "1999-01-01" })

      expect(status).to eq(404)
    end

    it "answers a session-less server/discover with a JSON-RPC 400 carrying the id, and creates no session" do
      status, _headers, body = rack("POST", body: { jsonrpc: "2.0", id: "probe-1", method: "server/discover", params: {} },
                                            headers: { "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28" })

      expect(status).to eq(400)
      expect(json(body)).to include("id" => "probe-1", "error" => include("code" => -32_600))
      expect(transport.sessions).to be_empty
    end
  end

  describe "body shape (§2.3a) and ids (§2.3b, §2.19)" do
    [ "[]", "[1,2,3]", '[299,{"x":"1"},["b"]]', "5", '"x"', "null" ].each do |raw|
      it "answers the body #{raw} with 400 -32600 JSON, never a client-chosen status or header" do
        status, headers, body = rack("POST", body: raw)

        expect(status).to eq(400)
        expect(headers["Content-Type"]).to eq("application/json")
        expect(json(body)["error"]["code"]).to eq(-32_600)
        expect(json(body)).not_to have_key("id")
      end
    end

    it "answers a missing jsonrpc member with 400 -32600 echoing the id" do
      status, _headers, body = rack("POST", body: { id: 3, method: "initialize" })

      expect(status).to eq(400)
      expect(json(body)).to include("id" => 3)
    end

    it "answers an invalid UTF-8 object key with 400 -32700, not 500" do
      status, _headers, body = rack("POST", body: %({"jsonrpc":"2.0","id":1,"\xFF":1}).b)

      expect(status).to eq(400)
      expect(json(body)["error"]["code"]).to eq(-32_700)
    end

    it "refuses a graph_write with \"id\": null and creates nothing" do
      _status, session_id, = initialize_session
      payload = { jsonrpc: "2.0", id: nil, method: "tools/call",
                  params: { name: "graph_write", arguments: { operations: [ { type: "create_entity", name: "SynthWidget Null", entity_type: "Task" } ] } } }

      status, _headers, body = rack("POST", body: payload, session_id: session_id)

      expect(status).to eq(400)
      expect(json(body)).not_to have_key("id")
      expect(json(body)["error"]).to include("code" => -32_600, "data" => "Request ID must not be null")
      expect(MemoryEntity.where(name: "SynthWidget Null")).not_to exist
    end

    it "accepts an id-less tools/call with 202 but doesn't run it" do
      _status, session_id, = initialize_session
      payload = { jsonrpc: "2.0", method: "tools/call",
                  params: { name: "graph_write", arguments: { operations: [ { type: "create_entity", name: "SynthWidget Blind", entity_type: "Task" } ] } } }

      expect(rack("POST", body: payload, session_id: session_id).first).to eq(202)
      expect(MemoryEntity.where(name: "SynthWidget Blind")).not_to exist
    end

    it "accepts a client's JSON-RPC response (result or error, with an id) with 202 at once" do
      _status, session_id, = initialize_session

      [ { result: {} }, { error: { code: -32_601, message: "Method not found" } } ].each_with_index do |reply, index|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, _headers, body = rack("POST", body: { jsonrpc: "2.0", id: "srv-#{index}" }.merge(reply), session_id: session_id)

        expect([ status, body ]).to eq([ 202, "" ])
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      end
    end

    it "still accepts notifications/initialized with 202" do
      _status, session_id, = initialize_session

      expect(rack("POST", body: { jsonrpc: "2.0", method: "notifications/initialized" }, session_id: session_id).first).to eq(202)
    end

    it "echoes the id on 404 for an unknown session and on 400 for a missing one" do
      expect(json(rpc("nope", "ping", id: 11)[2])).to include("id" => 11)
      expect(json(rack("POST", body: { jsonrpc: "2.0", id: 12, method: "ping" })[2])).to include("id" => 12)
    end
  end

  describe "sessions (§2.4)" do
    context "at the session cap" do
      let(:options) { { max_sessions: 2 } }

      it "evicts the least recently active idle session instead of refusing" do
        _status, older, = initialize_session
        _status, newer, = initialize_session
        sleep 0.01
        rpc(older, "ping") # now the older session is the more recently active one

        status, new_session, = initialize_session

        expect(status).to eq(200)
        expect(transport.sessions.keys).to contain_exactly(older, new_session)
        expect(rpc(newer, "ping").first).to eq(404)
      end

      it "refuses a new session with 503 when every session is busy" do
        2.times { open_get_stream(initialize_session[1]) }
        status, _headers, body = rack("POST", body: { jsonrpc: "2.0", id: 9, method: "initialize", params: {} })

        expect(status).to eq(503)
        expect(json(body)).to include("id" => 9, "error" => include("message" => "Too many sessions"))
      end
    end

    context "at the session cap with expired sessions" do
      let(:options) { { max_sessions: 1, session_timeout: 0 } }

      it "reaps expired sessions before refusing" do
        initialize_session
        sleep 0.01

        expect(initialize_session.first).to eq(200)
      end
    end

    it "keeps only the client's name and version on the session" do
      _status, session_id, = initialize_session

      expect(transport.sessions[session_id]).to include(client_info: { name: "SynthWidget", version: "1" },
                                                        negotiated_protocol_version: "2025-11-25")
    end

    it "answers a second GET stream for the same session with 409" do
      _status, session_id, = initialize_session

      expect(open_get_stream(session_id)).to eq(-1)
      expect(open_get_stream(session_id)).to eq(409)
    end
  end

  describe "legacy delegation" do
    it "keeps the server's transport after a /mcp/messages request" do
      transport # building it makes it the server's transport
      expect(server.transport).to equal(transport)

      rack("POST", path: "/mcp/messages", body: { jsonrpc: "2.0", id: 1, method: "ping" })

      expect(server.transport).to equal(transport)
    end
  end

  describe "CORS (§2.9)" do
    it "reflects an allowed Origin with Vary: Origin, never '*'" do
      _status, headers, = rack("OPTIONS", headers: { "HTTP_ORIGIN" => "http://localhost:5173" })

      expect(headers["access-control-allow-origin"]).to eq("http://localhost:5173")
      expect(headers["vary"]).to eq("Origin")
      expect(headers["access-control-allow-headers"]).to include("MCP-Protocol-Version")
    end

    it "refuses a preflight from a disallowed Origin with 403" do
      expect(rack("OPTIONS", headers: { "HTTP_ORIGIN" => "https://evil.example" }).first).to eq(403)
    end

    it "sends no Access-Control-Allow-Origin when the request has no Origin" do
      _status, headers, = initialize_session.then { rack("OPTIONS") }

      expect(headers).not_to have_key("access-control-allow-origin")
    end
  end
end
