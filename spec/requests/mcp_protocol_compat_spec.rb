# frozen_string_literal: true

require "rails_helper"
require "open3"
require Rails.root.join("script/mcp_compat/handshake_cases")

# mcp plan PR-3 §3.1 step 2: replays every handshake case in spec/fixtures/mcp/handshakes/ and
# asserts graph_mem's expectations. Wire-level only (status, headers, JSON-RPC bodies, stdout
# lines, DB side effects), so the same spec holds whichever MCP engine serves the requests.
# script/mcp_compat/compare.rb runs the same cases against the v2.0.0 reference servers.
RSpec.describe "MCP protocol compatibility (handshake fixtures)", type: :request do
  cases = McpCompat::HandshakeCases

  describe "Streamable HTTP" do
    after { AgentContext.delete_all }

    def call_app(verb, body: nil, headers: {}, hijack: false)
      env = Rack::MockRequest.env_for("/mcp", method: verb, input: body.to_s, "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost")
      McpCompat::HandshakeCases::BASE_HEADERS.merge(headers).each do |name, value|
        name == "Content-Type" ? env["CONTENT_TYPE"] = value : env["HTTP_#{name.upcase.tr('-', '_')}"] = value
      end
      if hijack
        env["rack.hijack"] = -> { }
        env["rack.hijack_io"] = StringIO.new
      end
      status, response_headers, response_body = Rails.application.call(env)
      text = +""
      response_body.each { |chunk| text << chunk } unless status == -1
      response_body.close if response_body.respond_to?(:close)
      McpCompat::HandshakeCases::Response.new(status: status, headers: response_headers.transform_keys(&:downcase), body: text)
    end

    def open_session
      session_id = call_app("POST", body: McpCompat::HandshakeCases.initialize_body).headers["mcp-session-id"]
      call_app("POST", body: JSON.generate(jsonrpc: "2.0", method: "notifications/initialized"),
                       headers: { "Mcp-Session-Id" => session_id, "MCP-Protocol-Version" => McpCompat::HandshakeCases::NEW_SESSION_VERSION })
      session_id
    end

    def close_session(session_id)
      call_app("DELETE", headers: { "Mcp-Session-Id" => session_id }) if session_id
    end

    def replay(kase)
      session_id = { "new" => -> { open_session }, "unknown" => -> { "mcp-compat-no-such-session" } }[kase["session"]]&.call
      session_headers = session_id ? { "Mcp-Session-Id" => session_id } : {}
      if kase["kind"] == "second_get_stream"
        stream_headers = session_headers.merge("Accept" => "text/event-stream")
        call_app("GET", headers: stream_headers, hijack: true)
        return call_app("GET", headers: stream_headers, hijack: true)
      end

      request = kase["request"]
      response = call_app("POST", body: McpCompat::HandshakeCases.http_body(request),
                                  headers: session_headers.merge(request.fetch("headers", {})))
      close_session(response.headers["mcp-session-id"])
      response
    ensure
      close_session(session_id) if kase["session"] == "new"
    end

    cases.load(:http).each do |kase|
      it kase["name"] do
        response = nil
        expect { response = replay(kase) }.not_to change(ToolInvocation, :count)

        expect(McpCompat::HandshakeCases.check_http(kase.dig("expect", "graph_mem"), response)).to eq([])
      end
    end
  end

  describe "stdio (bin/mcp_stdio_runner.rb, one process per case)" do
    # The runners are other processes, so their writes are committed: no transaction to roll back.
    self.use_transactional_tests = false

    stdio_cases = cases.load(:stdio)

    # Runs every case up front, four runners at a time (each boots Rails, about a second).
    before(:context) do
      started_at = Time.current
      @tool_invocations_before = ToolInvocation.count
      queue = Queue.new
      stdio_cases.each { |kase| queue << kase }
      @outputs = {}
      lock = Mutex.new
      Array.new(4) do
        Thread.new do
          while (kase = (queue.pop(true) rescue nil))
            output = run_runner(kase["send"].map { |item| McpCompat::HandshakeCases.stdio_line(item) })
            lock.synchronize { @outputs[kase["name"]] = output }
          end
        end
      end.each(&:join)
      @tool_invocations_after = ToolInvocation.count
    ensure
      AgentContext.where(created_at: started_at..).delete_all
    end

    # Sends the lines, closes stdin, and reads stdout to EOF. @return [Array<String>] stdout lines
    def run_runner(lines)
      env = { "RAILS_ENV" => "test", "OLLAMA_URL" => "http://127.0.0.1:9", "GRAPH_MEM_MCP_PROFILE" => "default" }
      Open3.popen3(env, RbConfig.ruby, Rails.root.join("bin/mcp_stdio_runner.rb").to_s, chdir: Rails.root.to_s) do |stdin, stdout, stderr, wait|
        stdin.binmode
        lines.each { |line| stdin.write(line, "\n") }
        stdin.close
        err_reader = Thread.new { stderr.read }
        out = Timeout.timeout(90) { stdout.read }
        Timeout.timeout(30) { wait.value }
        err_reader.join
        out.lines
      end
    end

    it "runs no tool in any case" do
      expect(@tool_invocations_after).to eq(@tool_invocations_before)
    end

    stdio_cases.each do |kase|
      it kase["name"] do
        replies, junk = McpCompat::HandshakeCases.parse_stdout(@outputs.fetch(kase["name"]))

        expect(McpCompat::HandshakeCases.check_stdio(kase.dig("expect", "graph_mem"), replies: replies, junk: junk)).to eq([])
      end
    end
  end
end
