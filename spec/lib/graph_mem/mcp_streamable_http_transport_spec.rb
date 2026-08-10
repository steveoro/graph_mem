# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphMem::McpStreamableHttpTransport do
  class RecordingMcpIO
    attr_reader :data

    def initialize
      @data = +""
      @closed = false
      @mutex = Mutex.new
    end

    def write(value)
      @mutex.synchronize do
        raise IOError, "closed" if @closed

        @data << value
      end
      value.bytesize
    end

    def flush
      nil
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def close
      @mutex.synchronize { @closed = true }
    end
  end

  class McpTransportTestServer
    attr_accessor :transport
    attr_reader :logger

    def initialize(logger)
      @logger = logger
    end

    def handle_request(_body, headers: {})
      transport.send_message(
        jsonrpc: "2.0",
        id: 1,
        result: { ok: true, headers_present: headers.any? }
      )
    end
  end

  class BlockingMcpIO
    def initialize
      @closed = false
      @started = false
      @condition = ConditionVariable.new
      @mutex = Mutex.new
    end

    def write(_value)
      @mutex.synchronize do
        @started = true
        @condition.broadcast
        @condition.wait(@mutex) until @closed
      end
      raise IOError, "closed"
    end

    def flush
      nil
    end

    def wait_until_started
      Timeout.timeout(2) do
        @mutex.synchronize do
          @condition.wait(@mutex) until @started
        end
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def close
      @mutex.synchronize do
        @closed = true
        @condition.broadcast
      end
    end
  end

  let(:logger) { Logger.new(IO::NULL) }
  let(:server) { McpTransportTestServer.new(logger) }
  let(:app) { ->(_env) { [ 404, {}, [] ] } }
  let(:transport) do
    described_class.new(
      app,
      server,
      session_timeout: 0.1,
      reaper_interval: 0,
      stream_queue_size: 2
    )
  end

  def build_registered_session(id = SecureRandom.uuid)
    session = transport.send(:build_session, id, "2025-03-26")
    transport.sessions[id] = session
    session
  end

  describe "stream lifecycle" do
    it "streams a POST response with the session id" do
      session = build_registered_session
      io = RecordingMcpIO.new
      response_queue = Queue.new
      env = Rack::MockRequest.env_for(
        "/mcp",
        method: "POST",
        input: "{}",
        "CONTENT_TYPE" => "application/json"
      )
      env["rack.hijack"] = lambda do
        env["rack.hijack_io"] = io
        io
      end
      request = Rack::Request.new(env)
      Thread.current[:graph_mem_mcp_response_queue] = response_queue

      result = transport.send(
        :streamable_post_sse_response,
        env,
        session,
        response_queue,
        session[:id],
        "{}",
        request
      )

      expect(result).to eq([ -1, {}, [] ])
      Timeout.timeout(2) do
        sleep 0.01 until io.data.include?("Mcp-Session-Id: #{session[:id]}")
      end
      expect(io.data).to include("Access-Control-Expose-Headers: Mcp-Session-Id")
    ensure
      Thread.current[:graph_mem_mcp_response_queue] = nil
      transport.send(:close_session, session) if session
    end

    it "closes a blocked hijacked IO when the session is closed" do
      session = build_registered_session
      io = BlockingMcpIO.new
      stream = transport.send(:register_stream, session, io)
      thread = Thread.new { transport.send(:streamable_get_loop, session, stream, session[:id]) }

      io.wait_until_started
      transport.send(:close_session, session)

      expect(thread.join(2)).to be_a(Thread)
      expect(io).to be_closed
      expect(stream[:closed]).to be(true)
      expect(session[:streams]).to be_empty
    end

    it "exits a normal stream and closes its IO after cleanup" do
      session = build_registered_session
      io = RecordingMcpIO.new
      stream = transport.send(:register_stream, session, io)
      thread = Thread.new { transport.send(:streamable_get_loop, session, stream, session[:id]) }

      expect { sleep 0.01 }.not_to raise_error
      transport.send(:close_session, session)

      expect(thread.join(2)).to be_a(Thread)
      expect(io).to be_closed
      expect(session[:streams]).to be_empty
    end

    it "cleans up the stream if the stream thread cannot be started" do
      session = build_registered_session
      io = RecordingMcpIO.new
      env = Rack::MockRequest.env_for(
        "/mcp",
        method: "GET",
        "HTTP_MCP_SESSION_ID" => session[:id],
        "HTTP_ACCEPT" => "text/event-stream"
      )
      env["rack.hijack"] = lambda do
        env["rack.hijack_io"] = io
        io
      end
      request = Rack::Request.new(env)

      allow(Thread).to receive(:new).and_raise(ThreadError, "thread limit")

      expect {
        transport.send(:handle_streamable_get, request, env)
      }.to raise_error(ThreadError, "thread limit")
      expect(io).to be_closed
      expect(session[:streams]).to be_empty
    end

    it "delivers notifications to every stream and removes them independently" do
      session = build_registered_session
      first = transport.send(:register_stream, session, RecordingMcpIO.new)
      second = transport.send(:register_stream, session, RecordingMcpIO.new)
      message = { jsonrpc: "2.0", method: "notifications/test", params: {} }

      transport.send(:broadcast_to_session_streams, session, message)

      expect(first[:queue].pop).to eq(message)
      expect(second[:queue].pop).to eq(message)

      transport.send(:close_stream, session, first)
      expect(session[:streams]).to contain_exactly(second)

      transport.send(:close_session, session)
      expect(session[:streams]).to be_empty
    end

    it "closes a slow stream instead of blocking when its queue is full" do
      session = build_registered_session
      stream = transport.send(:register_stream, session, RecordingMcpIO.new)
      first = { jsonrpc: "2.0", method: "notifications/one" }
      second = { jsonrpc: "2.0", method: "notifications/two" }
      third = { jsonrpc: "2.0", method: "notifications/three" }

      transport.send(:enqueue_stream, session, stream, first)
      transport.send(:enqueue_stream, session, stream, second)
      transport.send(:enqueue_stream, session, stream, third)

      expect(stream[:closed]).to be(true)
      expect(session[:streams]).to be_empty
    end
  end

  describe "session reaping" do
    it "reaps idle sessions and leaves active sessions alone" do
      idle = build_registered_session("idle")
      idle[:last_active_at] = transport.send(:monotonic_time) - 1

      active = build_registered_session("active")
      active[:last_active_at] = transport.send(:monotonic_time) - 1
      active[:active_requests] = 1

      streaming = build_registered_session("streaming")
      transport.send(:register_stream, streaming, RecordingMcpIO.new)
      streaming[:last_active_at] = transport.send(:monotonic_time) - 1

      transport.send(:reap_expired_sessions)

      expect(transport.sessions).not_to have_key("idle")
      expect(transport.sessions).to have_key("active")
      expect(transport.sessions).to have_key("streaming")

      transport.send(:release_session, active)
      transport.send(:close_session, active)
      transport.send(:close_session, streaming)
    end

    it "does not scan before the configured reaper interval" do
      transport.instance_variable_set(:@reaper_interval, 60)
      transport.instance_variable_set(:@last_reaped_at, transport.send(:monotonic_time))
      session = build_registered_session("deferred")
      session[:last_active_at] = transport.send(:monotonic_time) - 1

      transport.send(:reap_expired_sessions)

      expect(transport.sessions).to have_key("deferred")
      transport.send(:close_session, session)
    end
  end
end
