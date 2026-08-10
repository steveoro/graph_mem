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

    SSE_HEADERS = {
      "Content-Type" => "text/event-stream",
      "Cache-Control" => "no-cache, no-store, must-revalidate",
      "Connection" => "keep-alive",
      "X-Accel-Buffering" => "no",
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Content-Type, Mcp-Session-Id, X-MCP-Client",
      "Access-Control-Max-Age" => "86400",
      "Keep-Alive" => "timeout=600",
      "Pragma" => "no-cache",
      "Expires" => "0"
    }.freeze

    CORS_HEADERS = {
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers" => "Content-Type, Mcp-Session-Id, X-MCP-Client",
      "Access-Control-Max-Age" => "86400",
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
      @legacy_transport = FastMcp::Transports::RackTransport.new(app, server, options)
      @sessions = Concurrent::Hash.new

      # Ensure the server has a transport reference for out-of-request notifications.
      @server.transport = self
    end

    def start
      @legacy_transport.start
      @logger.info("Started GraphMem::McpStreamableHttpTransport at #{@path_prefix}")
    end

    def stop
      @legacy_transport.stop
      @sessions.each do |_id, session|
        close_session(session)
      end
      @sessions.clear
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
        queue.push(message)
        return
      end

      # Notifications (no id) should be broadcast, even if a request is in
      # progress. The client will receive them on its SSE stream, not as a
      # request response body.
      session_id = Thread.current[:graph_mem_mcp_session_id]

      if session_id && (session = @sessions[session_id])
        broadcast_to_session_get_queues(session, message)
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

      session[:last_active_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Notifications (no id) get a 202 Accepted and do not return a body.
      if request_id.nil?
        @server.handle_request(body, headers: extract_headers(request))
        return [ 202, CORS_HEADERS.dup, [] ]
      end

      wants_sse = sse_response_requested?(accept)

      if wants_sse && !env["rack.hijack"]
        return json_rpc_error_response(406, -32_600, "Not Acceptable: SSE response requires rack.hijack support")
      end

      queue = Queue.new

      # For SSE-mode POSTs, the single queue is both the response carrier and
      # the long-lived SSE stream for the session. Register it so future
      # server-initiated notifications are also delivered to the same stream.
      register_get_queue(session, queue) if wants_sse

      Thread.current[:graph_mem_mcp_session_id] = session_id
      Thread.current[:graph_mem_mcp_response_queue] = queue

      if wants_sse
        return streamable_post_sse_response(env, session, queue, session_id, body, request)
      end

      handle_streamable_post_json(session, queue, session_id, body, request)
    ensure
      Thread.current[:graph_mem_mcp_session_id] = nil
      Thread.current[:graph_mem_mcp_response_queue] = nil
    end

    def streamable_post_sse_response(env, session, queue, session_id, body, request)
      env["rack.hijack"].call
      io = env["rack.hijack_io"]

      Thread.new do
        streamable_get_loop(session, io, queue, session_id)
      end

      @server.handle_request(body, headers: extract_headers(request))

      [ -1, {}, [] ]
    ensure
      Thread.current[:graph_mem_mcp_session_id] = nil
      Thread.current[:graph_mem_mcp_response_queue] = nil
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

      headers = { "Content-Type" => "application/json" }
      headers["Mcp-Session-Id"] = session_id
      [ 200, headers, [ message_to_json(response) ] ]
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

      session = @sessions[session_id]
      return json_rpc_error_response(404, -32_001, "Session not found") unless session

      return method_not_allowed_response unless env["rack.hijack"]

      env["rack.hijack"].call
      io = env["rack.hijack_io"]

      queue = Queue.new
      register_get_queue(session, queue)
      session[:last_active_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Thread.new { streamable_get_loop(session, io, queue, session_id) }

      [ -1, {}, [] ]
    end

    def handle_streamable_delete(request, _env)
      session_id = request.env["HTTP_MCP_SESSION_ID"]
      if session_id.nil? || session_id.empty?
        return json_rpc_error_response(400, -32_600, "Bad Request: missing Mcp-Session-Id header")
      end

      session = @sessions.delete(session_id)
      return json_rpc_error_response(404, -32_001, "Session not found") unless session

      close_session(session)

      [ 200, CORS_HEADERS.dup, [] ]
    end

    def resolve_session(request, parsed, method)
      if method == "initialize"
        session_id = SecureRandom.uuid
        requested_version = parsed.dig(:params, :protocolVersion) || parsed.dig(:params, "protocolVersion").to_s
        version = requested_version.to_s >= "2025-03-26" ? "2025-03-26" : "2024-11-05"

        session = {
          id: session_id,
          requested_protocol_version: version,
          get_queues: Concurrent::Array.new,
          last_active_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
        }
        @sessions[session_id] = session

        [ session_id, session ]
      else
        session_id = request.env["HTTP_MCP_SESSION_ID"]
        if session_id.nil? || session_id.empty?
          return [ nil, json_rpc_error_response(400, -32_600, "Bad Request: missing Mcp-Session-Id header") ]
        end

        session = @sessions[session_id]
        unless session
          return [ nil, json_rpc_error_response(404, -32_001, "Session not found") ]
        end

        if session_expired?(session)
          @sessions.delete(session_id)
          close_session(session)
          return [ nil, json_rpc_error_response(404, -32_001, "Session expired") ]
        end

        [ session_id, session ]
      end
    end

    def streamable_get_loop(session, io, queue, session_id)
      write_sse_headers(io)

      loop do
        session[:last_active_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          message = queue.pop(true)
          write_sse_message(io, message)
        rescue ThreadError
          # No message waiting; send a keep-alive comment.
          write_sse_keep_alive(io)
          sleep 1
        end
      end
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      @logger.info("Streamable SSE client #{session_id} disconnected")
    ensure
      unregister_get_queue(session, queue)
    end

    def register_get_queue(session, queue)
      session[:get_queues] ||= Concurrent::Array.new
      session[:get_queues] << queue
    end

    def unregister_get_queue(session, queue)
      session[:get_queues]&.delete(queue)
    end

    def broadcast_to_session_get_queues(session, message)
      queues = session[:get_queues]
      return unless queues

      queues.each do |queue|
        queue.push(message)
      rescue ClosedQueueError
        # Queue closed; its reader will unregister it on exit.
      end
    end

    def broadcast_to_streamable_sessions(message)
      @sessions.each_value do |session|
        broadcast_to_session_get_queues(session, message)
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

    def message_to_json(message)
      message.is_a?(String) ? message : JSON.generate(message)
    end

    def write_sse_headers(io)
      io.write("HTTP/1.1 200 OK\r\n")
      SSE_HEADERS.each { |key, value| io.write("#{key}: #{value}\r\n") }
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

      if (queues = session[:get_queues])
        queues.each(&:close)
      end
      if (io = session[:io])
        io.close unless io.closed?
      end
    end

    def session_expired?(session)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - session[:last_active_at] > SESSION_TIMEOUT
    end

    def reap_expired_sessions
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @sessions.each do |session_id, session|
        next if now - session[:last_active_at] <= SESSION_TIMEOUT

        @sessions.delete(session_id)
        close_session(session)
        @logger.info("Reaped expired MCP session #{session_id}")
      end
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
      [ http_status, { "Content-Type" => "application/json" },
       [ JSON.generate(jsonrpc: "2.0", error: { code: code, message: message }, id: id) ] ]
    end
  end
end
