# frozen_string_literal: true

require "securerandom"
require "json"
require "timeout"
require "concurrent"
require "rack"

module GraphMem
  # Rack transport for FastMcp that supports the 2025-03-26 Streamable HTTP
  # transport while preserving the legacy 2024-11-05 SSE transport.
  #
  # Endpoints:
  #   POST /mcp          - Streamable HTTP JSON-RPC request/response
  #   GET  /mcp          - Streamable HTTP SSE stream (server -> client)
  #   DELETE /mcp        - terminate a Streamable HTTP session
  #   GET  /mcp/sse      - legacy 2024-11-05 SSE endpoint
  #   POST /mcp/messages - legacy 2024-11-05 message endpoint
  #
  # The legacy endpoints are delegated to an inner FastMcp::Transports::RackTransport
  # so the existing SSE behaviour and client configs keep working without a rewrite.
  # Only public methods on the inner transport are used.
  class McpStreamableHttpTransport < FastMcp::Transports::BaseTransport
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

    SSE_HEADERS = {
      "Content-Type" => "text/event-stream",
      "Cache-Control" => "no-cache, no-store, must-revalidate",
      "Connection" => "keep-alive",
      "X-Accel-Buffering" => "no",
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Content-Type, Mcp-Session-Id, X-MCP-Client",
      "Access-Control-Expose-Headers" => "Mcp-Session-Id",
      "Access-Control-Max-Age" => "86400",
      "Keep-Alive" => "timeout=600",
      "Pragma" => "no-cache",
      "Expires" => "0"
    }.freeze

    CORS_HEADERS = {
      "access-control-allow-origin" => "*",
      "access-control-allow-methods" => "GET, POST, DELETE, OPTIONS",
      "access-control-allow-headers" => "Content-Type, Mcp-Session-Id, X-MCP-Client",
      "access-control-expose-headers" => "Mcp-Session-Id",
      "access-control-max-age" => "86400",
      "Content-Type" => "text/plain"
    }.freeze

    RESPONSE_TIMEOUT = 30

    attr_reader :app, :path_prefix, :messages_route, :sse_route, :allowed_origins,
                :allowed_ips, :localhost_only, :legacy_transport, :sessions

    def initialize(app, server, options = {})
      super(server, logger: options[:logger])

      @app = app
      @path_prefix = options[:path_prefix] || DEFAULT_PATH_PREFIX
      @messages_route = options[:messages_route] || DEFAULT_MESSAGES_ROUTE
      @sse_route = options[:sse_route] || DEFAULT_SSE_ROUTE
      @allowed_origins = options[:allowed_origins] || DEFAULT_ALLOWED_ORIGINS.dup
      @allowed_ips = options[:allowed_ips] || DEFAULT_ALLOWED_IPS.dup
      @localhost_only = options.fetch(:localhost_only, true)
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

    # Called by FastMcp::Server#send_response (via GraphMem::McpServerPatch).
    # Routes per-request responses to the active request queue (if one is
    # registered for this thread) and broadcasts notifications to every
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

      subpath = request.path[@path_prefix.length..]

      case subpath
      when "/#{@sse_route}", "/#{@messages_route}"
        # Legacy 2024-11-05 endpoints are handled entirely by FastMcp's transport.
        Thread.current[:graph_mem_mcp_transport] = @legacy_transport
        @legacy_transport.call(env)
      when "", "/"
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
        @server.handle_request(body, headers: extract_headers(request))
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
      @server.handle_request(body, headers: extract_headers(request))

      [ -1, {}, [] ]
    rescue StandardError
      close_stream(session, stream) if stream
      close_io(io) unless stream
      raise
    end

    def handle_streamable_post_json(session, queue, session_id, body, request)
      response = nil
      begin
        @server.handle_request(body, headers: extract_headers(request))
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

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def build_session(session_id, protocol_version)
      {
        id: session_id,
        requested_protocol_version: protocol_version,
        streams: [],
        active_requests: 0,
        last_active_at: monotonic_time,
        closed: false
      }
    end

    def lease_existing_session(session_id)
      expired_session = nil
      session = @sessions_mutex.synchronize do
        candidate = @sessions[session_id]
        if candidate.nil? || candidate[:closed]
          nil
        elsif session_expired_locked?(candidate, monotonic_time)
          candidate[:closed] = true
          @sessions.delete(session_id) if @sessions[session_id].equal?(candidate)
          expired_session = candidate
          nil
        else
          candidate[:active_requests] += 1
          candidate[:last_active_at] = monotonic_time
          candidate
        end
      end

      close_session(expired_session) if expired_session
      return [ nil, :expired ] if expired_session
      return [ nil, :missing ] unless session

      [ session, nil ]
    end

    def release_session(session)
      @sessions_mutex.synchronize do
        session[:active_requests] -= 1 if session[:active_requests].positive?
        session[:last_active_at] = monotonic_time unless session[:closed]
      end
    end

    def touch_session!(session)
      @sessions_mutex.synchronize do
        session[:last_active_at] = monotonic_time unless session[:closed]
      end
    end

    def session_for_id(session_id)
      return unless session_id

      @sessions_mutex.synchronize do
        session = @sessions[session_id]
        session unless session&.[](:closed)
      end
    end

    def remove_session(session_id)
      @sessions_mutex.synchronize do
        session = @sessions[session_id]
        next unless session

        session[:closed] = true
        @sessions.delete(session_id) if @sessions[session_id].equal?(session)
        session
      end
    end

    def register_stream(session, io, response_queue = nil)
      stream = {
        queue: SizedQueue.new(@stream_queue_size),
        response_queue: response_queue,
        io: io,
        closed: false,
        mutex: Mutex.new
      }

      registered = @sessions_mutex.synchronize do
        if session[:closed] || !@sessions[session[:id]].equal?(session)
          false
        else
          session[:streams] << stream
          session[:last_active_at] = monotonic_time
          true
        end
      end

      registered ? stream : nil
    end

    def unregister_stream(session, stream)
      @sessions_mutex.synchronize do
        session[:streams]&.delete(stream)
      end
    end

    def streamable_get_loop(session, stream, session_id)
      write_sse_headers(stream[:io], "Mcp-Session-Id" => session_id)

      loop do
        break if stream_closed?(stream)

        touch_session!(session)
        message = next_stream_message(stream)

        if message
          write_sse_message(stream[:io], message)
        else
          break if stream_closed?(stream)

          # No message waiting; send a keep-alive comment.
          write_sse_keep_alive(stream[:io])
          sleep 1
        end
      end
    rescue IOError, EOFError, SystemCallError
      @logger.info("Streamable SSE client #{session_id} disconnected")
    ensure
      unregister_stream(session, stream)
      close_stream(session, stream)
    end

    def next_stream_message(stream)
      [ stream[:response_queue], stream[:queue] ].compact.each do |queue|
        begin
          return queue.pop(true)
        rescue ThreadError
          next
        end
      end

      nil
    end

    def stream_closed?(stream)
      stream[:mutex].synchronize { stream[:closed] }
    end

    def close_stream(session, stream)
      return unless stream

      should_close = stream[:mutex].synchronize do
        if stream[:closed]
          false
        else
          stream[:closed] = true
          true
        end
      end
      return unless should_close

      [ stream[:queue], stream[:response_queue] ].compact.each do |queue|
        queue.close unless queue.closed?
      end
      close_io(stream[:io])
      unregister_stream(session, stream) if session
    end

    def close_io(io)
      return unless io

      io.close unless io.closed?
    rescue IOError, SystemCallError
      nil
    end

    def enqueue_stream(session, stream, message)
      return if stream_closed?(stream)

      stream[:queue].push(message, true)
    rescue ThreadError
      @logger.warn("Closing a slow Streamable HTTP SSE stream")
      close_stream(session, stream)
    end

    def broadcast_to_session_streams(session, message)
      streams = @sessions_mutex.synchronize do
        session[:closed] ? [] : session[:streams].dup
      end
      streams.each { |stream| enqueue_stream(session, stream, message) }
    end

    def broadcast_to_streamable_sessions(message)
      sessions = @sessions_mutex.synchronize { @sessions.values.dup }
      sessions.each { |session| broadcast_to_session_streams(session, message) }
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

    def message_to_json(message)
      message.is_a?(String) ? message : JSON.generate(message)
    end

    def json_response_headers(session_id = nil)
      headers = CORS_HEADERS.merge("Content-Type" => "application/json")
      headers["Mcp-Session-Id"] = session_id if session_id
      headers
    end

    def write_sse_headers(io, extra_headers = {})
      io.write("HTTP/1.1 200 OK\r\n")
      SSE_HEADERS.merge(extra_headers).each { |key, value| io.write("#{key}: #{value}\r\n") }
      io.write("\r\n")
      io.write(": SSE connection established\n\n")
      io.flush
    end

    def write_sse_message(io, message)
      json = message_to_json(message)
      io.write("event: message\ndata: #{json}\n\n")
      io.flush
    end

    def write_sse_keep_alive(io)
      io.write(": keep-alive\n\n")
      io.flush
    end

    def close_session(session)
      return unless session

      streams = @sessions_mutex.synchronize do
        session[:closed] = true
        streams = session[:streams].dup
        session[:streams].clear
        streams
      end
      streams.each { |stream| close_stream(nil, stream) }
    end

    def session_expired_locked?(session, now)
      !session[:closed] &&
        session[:active_requests].zero? &&
        session[:streams].empty? &&
        now - session[:last_active_at] > @session_timeout
    end

    def reap_expired_sessions
      return unless @reaper_mutex.try_lock

      expired_sessions = []
      begin
        now = monotonic_time
        return if now - @last_reaped_at < @reaper_interval

        @last_reaped_at = now
        @sessions_mutex.synchronize do
          @sessions.each do |session_id, session|
            next unless session_expired_locked?(session, now)
            next unless @sessions[session_id].equal?(session)

            session[:closed] = true
            @sessions.delete(session_id)
            expired_sessions << [ session_id, session ]
          end
        end
      ensure
        @reaper_mutex.unlock
      end

      expired_sessions.each { |_session_id, session| close_session(session) }
      @logger.info("Reaped #{expired_sessions.size} expired MCP sessions") if expired_sessions.any?
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

    # Re-implementing the simple DNS-rebinding / IP validation from FastMcp
    # keeps this transport self-contained and avoids relying on private methods.
    def valid_client_ip?(request)
      client_ip = request.ip

      if @localhost_only && !@allowed_ips.include?(client_ip)
        @logger.warn("Blocked connection from non-localhost IP: #{client_ip}")
        return false
      end

      true
    end

    def validate_origin(request, env)
      origin = env["HTTP_ORIGIN"]
      origin = env["HTTP_REFERER"] || request.host if origin.nil? || origin.empty?

      hostname = extract_hostname(origin)
      return true if hostname.nil? || allowed_origins.empty?

      allowed = allowed_origins.any? do |allowed_origin|
        if allowed_origin.is_a?(Regexp)
          hostname.match?(allowed_origin)
        else
          hostname == allowed_origin
        end
      end

      unless allowed
        @logger.warn("Blocked request with origin: #{hostname}")
        return false
      end

      true
    end

    def extract_hostname(url)
      return nil if url.nil? || url.empty?

      begin
        has_scheme = url.match?(%r{^[a-zA-Z][a-zA-Z0-9+.-]*://})
        parsing_url = has_scheme ? url : "http://#{url}"

        uri = URI.parse(parsing_url)
        return nil if uri.host.nil? || uri.host.empty?

        uri.host
      rescue URI::InvalidURIError
        url.split(":").first if url.match?(%r{^([^:/]+)(:\d+)?$})
      end
    end

    def forbidden_response(message)
      json_rpc_error_response(403, -32_600, message)
    end

    def endpoint_not_found_response
      json_rpc_error_response(404, -32_601, "Endpoint not found")
    end

    def method_not_allowed_response
      json_rpc_error_response(405, -32_601, "Method not allowed")
    end

    def json_rpc_error_response(http_status, code, message, id = nil)
      [ http_status, json_response_headers,
       [ JSON.generate(jsonrpc: "2.0", error: { code: code, message: message }, id: id) ] ]
    end
  end
end
