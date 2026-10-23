# frozen_string_literal: true

require "securerandom"
require "json"
require "timeout"
require "concurrent"
require "rack"
require_relative "mcp_access_policy"
require_relative "mcp_profile"
require_relative "mcp_streamable_http/headers"
require_relative "mcp_streamable_http/sessions"
require_relative "mcp_streamable_http/streams"
require_relative "mcp_streamable_http/responses"

module GraphMem
  # Rack transport for FastMcp that supports the 2025-03-26 Streamable HTTP
  # transport while preserving the legacy 2024-11-05 SSE transport.
  #
  # Endpoints:
  #   /mcp              - Streamable HTTP, default profile
  #   /mcp/readonly     - Streamable HTTP, context and read tools
  #   /mcp/maintenance  - Streamable HTTP, full catalog
  #   /mcp/sse          - legacy 2024-11-05 SSE, default profile
  #   /mcp/messages     - legacy 2024-11-05 messages, default profile
  #
  # The legacy endpoints are delegated to an inner FastMcp::Transports::RackTransport
  # so the existing SSE behaviour and client configs keep working without a rewrite.
  # Only public methods on the inner transport are used.
  class McpStreamableHttpTransport < FastMcp::Transports::BaseTransport
    include McpStreamableHttp::Sessions
    include McpStreamableHttp::Streams
    include McpStreamableHttp::Responses

    DEFAULT_PATH_PREFIX = "/mcp"
    DEFAULT_MESSAGES_ROUTE = "messages"
    DEFAULT_SSE_ROUTE = "sse"
    DEFAULT_ALLOWED_ORIGINS = FastMcp::Transports::RackTransport::DEFAULT_ALLOWED_ORIGINS
    DEFAULT_ALLOWED_IPS = FastMcp::Transports::RackTransport::DEFAULT_ALLOWED_IPS

    # Sessions are kept alive as long as they are active. A streamable GET
    # loop bumps last_active_at each second, so an open SSE stream is never
    # reaped. A session only used for POST JSON responses will expire after
    # this timeout if no request is made.
    SESSION_TIMEOUT = 30 * 60
    REAPER_INTERVAL = 60
    STREAM_QUEUE_SIZE = 100

    SSE_HEADERS = McpStreamableHttp::SSE_HEADERS
    CORS_HEADERS = McpStreamableHttp::CORS_HEADERS

    RESPONSE_TIMEOUT = 30

    attr_reader :app, :path_prefix, :messages_route, :sse_route, :allowed_origins,
                :allowed_ips, :localhost_only, :legacy_transport, :sessions, :access_policy

    def initialize(app, server, options = {})
      super(server, logger: options[:logger])

      @app = app
      @path_prefix = options[:path_prefix] || DEFAULT_PATH_PREFIX
      @messages_route = options[:messages_route] || DEFAULT_MESSAGES_ROUTE
      @sse_route = options[:sse_route] || DEFAULT_SSE_ROUTE
      @allowed_origins = options[:allowed_origins] || DEFAULT_ALLOWED_ORIGINS.dup
      @allowed_ips = options[:allowed_ips] || DEFAULT_ALLOWED_IPS.dup
      @localhost_only = options.fetch(:localhost_only, true)
      # Governs both the streamable and the legacy endpoints: handle_mcp_request
      # consults it before delegating, so @legacy_transport's own (string-equality
      # only) IP check is left inert rather than duplicated here.
      @access_policy = options[:access_policy] || GraphMem::McpAccessPolicy.from_env(logger: @logger)
      @session_timeout = options.fetch(:session_timeout, SESSION_TIMEOUT).to_f
      @reaper_interval = options.fetch(:reaper_interval, REAPER_INTERVAL).to_f
      @stream_queue_size = [ options.fetch(:stream_queue_size, STREAM_QUEUE_SIZE).to_i, 1 ].max
      @legacy_transport = FastMcp::Transports::RackTransport.new(app, server, options)
      @sessions = Concurrent::Hash.new
      @sessions_mutex = Mutex.new
      @reaper_mutex = Mutex.new
      @last_reaped_at = -Float::INFINITY

      # Ensure the server has a transport reference for out-of-request notifications.
      @server.transport = self
    end

    def start
      @legacy_transport.start
      @logger.info("Started GraphMem::McpStreamableHttpTransport at #{@path_prefix}")
    end

    def stop
      @legacy_transport.stop
      sessions = @sessions_mutex.synchronize do
        sessions = @sessions.values
        @sessions.clear
        sessions.each { |session| session[:closed] = true }
        sessions
      end
      sessions.each { |session| close_session(session) }
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path

      if path.start_with?(@path_prefix)
        reap_expired_sessions
        Thread.current[:graph_mem_mcp_transport] = self
        handle_mcp_request(request, env)
      else
        @app.call(env)
      end
    ensure
      Thread.current[:graph_mem_mcp_transport] = nil
      Thread.current[:graph_mem_mcp_session_id] = nil
      Thread.current[:graph_mem_mcp_response_queue] = nil
    end

    # Called by FastMcp::Server#send_response through the request context's
    # transport. Routes per-request responses to the active request queue (if
    # one is registered for this thread) and broadcasts notifications to every
    # connected SSE stream.
    def send_message(message)
      # If this is a response to a request with an id and a per-request queue
      # exists, deliver it directly. This avoids races on session[:response_queue]
      # and keeps the response off the public SSE stream.
      if response?(message) && (queue = Thread.current[:graph_mem_mcp_response_queue])
        begin
          queue.push(message)
        rescue ThreadError
          @logger.debug("MCP response queue was closed before delivery")
        end
        return
      end

      # Notifications (no id) should be broadcast, even if a request is in
      # progress. The client will receive them on its SSE stream, not as a
      # request response body.
      session_id = Thread.current[:graph_mem_mcp_session_id]
      session = session_for_id(session_id) if session_id

      if session
        broadcast_to_session_streams(session, message)
      else
        broadcast_to_streamable_sessions(message)
        @legacy_transport.send_message(message)
      end
    end

    private

    def response?(message)
      message.is_a?(Hash) && (message.key?(:id) || message.key?("id"))
    end

    def handle_mcp_request(request, env)
      return forbidden_response("Forbidden: Remote IP not allowed") unless valid_client_ip?(request)
      return forbidden_response("Forbidden: Origin validation failed") unless validate_origin(request, env)

      # CORS preflight carries no Authorization header, so it must be answered
      # before the token check or browser clients can never send credentials.
      return [ 200, CORS_HEADERS.dup, [] ] if request.env["REQUEST_METHOD"] == "OPTIONS"
      return unauthorized_response unless @access_policy.authenticated?(request)

      subpath = request.path[@path_prefix.length..]

      case subpath
      when "/#{@sse_route}", "/#{@messages_route}"
        # Legacy 2024-11-05 endpoints are handled entirely by FastMcp's transport.
        Thread.current[:graph_mem_mcp_transport] = @legacy_transport
        @legacy_transport.call(env)
      when "", "/", "/readonly", "/readonly/", "/maintenance", "/maintenance/"
        handle_streamable_request(request, env)
      else
        endpoint_not_found_response
      end
    end

    def handle_streamable_request(request, env)
      case request.env["REQUEST_METHOD"]
      when "OPTIONS"
        [ 200, CORS_HEADERS.dup, [] ]
      when "POST"
        handle_streamable_post(request, env)
      when "GET"
        handle_streamable_get(request, env)
      when "DELETE"
        handle_streamable_delete(request, env)
      else
        method_not_allowed_response
      end
    end

    def dispatch_server_request(body, request, session_id: nil)
      @server.with_request_context(transport: self, session_id: session_id, request: request) do
        @server.handle_request(body, headers: extract_headers(request))
      end
    end

    def handle_streamable_post(request, env)
      session = nil
      content_type = request.env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
      unless content_type == "application/json"
        return json_rpc_error_response(415, -32_600, "Unsupported Media Type: Content-Type must be application/json")
      end

      accept = request.env["HTTP_ACCEPT"].to_s
      unless acceptable_post_accept?(accept)
        return json_rpc_error_response(406, -32_600, "Not Acceptable: Accept must include application/json, text/event-stream, or */*")
      end

      body = request.body.read
      return json_rpc_error_response(400, -32_700, "Parse error: empty body") if body.empty?

      parsed = parse_json(body)
      return parsed if parsed.is_a?(Array) # error response

      method = parsed[:method] || parsed["method"]
      request_id = parsed.key?(:id) ? parsed[:id] : parsed["id"]

      session_id, session = resolve_session(request, parsed, method)
      return session if session.is_a?(Array) # error response

      # Notifications (no id) get a 202 Accepted and do not return a body.
      if request_id.nil?
        dispatch_server_request(body, request, session_id: session_id)
        return [ 202, CORS_HEADERS.dup, [] ]
      end

      wants_sse = sse_response_requested?(accept)

      if wants_sse && !env["rack.hijack"]
        return json_rpc_error_response(406, -32_600, "Not Acceptable: SSE response requires rack.hijack support")
      end

      response_queue = Queue.new
      Thread.current[:graph_mem_mcp_session_id] = session_id
      Thread.current[:graph_mem_mcp_response_queue] = response_queue

      if wants_sse
        return streamable_post_sse_response(env, session, response_queue, session_id, body, request)
      end

      handle_streamable_post_json(session, response_queue, session_id, body, request)
    ensure
      release_session(session) if session.is_a?(Hash)
      Thread.current[:graph_mem_mcp_session_id] = nil
      Thread.current[:graph_mem_mcp_response_queue] = nil
    end

    def streamable_post_sse_response(env, session, response_queue, session_id, body, request)
      env["rack.hijack"].call
      io = env["rack.hijack_io"]
      raise IOError, "MCP hijack did not provide an IO" unless io

      stream = register_stream(session, io, response_queue)
      raise IOError, "MCP session was closed before the SSE stream opened" unless stream

      stream[:thread] = Thread.new { streamable_get_loop(session, stream, session_id) }
      dispatch_server_request(body, request, session_id: session_id)

      [ -1, {}, [] ]
    rescue StandardError
      close_stream(session, stream) if stream
      close_io(io) unless stream
      raise
    end

    def handle_streamable_post_json(session, queue, session_id, body, request)
      response = nil
      begin
        dispatch_server_request(body, request, session_id: session_id)
        response = Timeout.timeout(RESPONSE_TIMEOUT) { queue.pop }
      rescue Timeout::Error
        return json_rpc_error_response(504, -32_600, "Gateway Timeout: no response from MCP server")
      ensure
        Thread.current[:graph_mem_mcp_session_id] = nil
        Thread.current[:graph_mem_mcp_response_queue] = nil
      end

      normalize_initialize_protocol_version!(session, response)

      [ 200, json_response_headers(session_id), [ message_to_json(response) ] ]
    end

    def handle_streamable_get(request, env)
      accept = request.env["HTTP_ACCEPT"].to_s
      unless accept.include?("text/event-stream") || accept.include?("*/*") || accept.empty?
        return json_rpc_error_response(406, -32_600, "Not Acceptable: Accept must include text/event-stream")
      end

      session_id = request.env["HTTP_MCP_SESSION_ID"]
      if session_id.nil? || session_id.empty?
        return json_rpc_error_response(400, -32_600, "Bad Request: missing Mcp-Session-Id header")
      end

      session, error = lease_existing_session(session_id)
      unless session
        return json_rpc_error_response(404, -32_001, error == :expired ? "Session expired" : "Session not found")
      end

      stream = nil
      io = nil
      begin
        return method_not_allowed_response unless env["rack.hijack"]

        env["rack.hijack"].call
        io = env["rack.hijack_io"]
        raise IOError, "MCP hijack did not provide an IO" unless io

        stream = register_stream(session, io)
        raise IOError, "MCP session was closed before the SSE stream opened" unless stream

        stream[:thread] = Thread.new { streamable_get_loop(session, stream, session_id) }

        [ -1, {}, [] ]
      rescue StandardError
        close_stream(session, stream) if stream
        close_io(io) unless stream
        raise
      ensure
        release_session(session)
      end
    end

    def handle_streamable_delete(request, _env)
      session_id = request.env["HTTP_MCP_SESSION_ID"]
      if session_id.nil? || session_id.empty?
        return json_rpc_error_response(400, -32_600, "Bad Request: missing Mcp-Session-Id header")
      end

      session = remove_session(session_id)
      return json_rpc_error_response(404, -32_001, "Session not found") unless session

      close_session(session)

      [ 200, CORS_HEADERS.dup, [] ]
    end

    def resolve_session(request, parsed, method)
      if method == "initialize"
        session_id = SecureRandom.uuid
        requested_version = parsed.dig(:params, :protocolVersion) || parsed.dig(:params, "protocolVersion").to_s
        version = requested_version.to_s >= "2025-03-26" ? "2025-03-26" : "2024-11-05"
        session = build_session(session_id, version)

        @sessions_mutex.synchronize do
          @sessions[session_id] = session
          session[:active_requests] += 1
          session[:last_active_at] = monotonic_time
        end

        [ session_id, session ]
      else
        session_id = request.env["HTTP_MCP_SESSION_ID"]
        if session_id.nil? || session_id.empty?
          return [ nil, json_rpc_error_response(400, -32_600, "Bad Request: missing Mcp-Session-Id header") ]
        end

        session, error = lease_existing_session(session_id)
        unless session
          message = error == :expired ? "Session expired" : "Session not found"
          return [ nil, json_rpc_error_response(404, -32_001, message) ]
        end

        [ session_id, session ]
      end
    end

    def normalize_initialize_protocol_version!(session, message)
      return unless message.is_a?(Hash)

      result = message[:result] || message["result"]
      return unless result.is_a?(Hash)

      if result.key?(:protocolVersion) || result.key?("protocolVersion")
        result[:protocolVersion] = session[:requested_protocol_version]
      end
    end

    def extract_headers(request)
      request.env
             .select { |key, _value| key.start_with?("HTTP_") }
             .transform_keys { |key| key.sub("HTTP_", "").downcase.tr("_", "-") }
    end

    def parse_json(body)
      JSON.parse(body, symbolize_names: true)
    rescue JSON::ParserError
      json_rpc_error_response(400, -32_700, "Parse error: Invalid JSON")
    end

    def acceptable_post_accept?(accept)
      accept.empty? ||
        accept.include?("*/*") ||
        accept.include?("application/json") ||
        accept.include?("text/event-stream")
    end

    def sse_response_requested?(accept)
      accept.include?("text/event-stream") &&
        !accept.include?("application/json") &&
        !accept.include?("*/*")
    end
  end
end
