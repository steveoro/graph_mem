# frozen_string_literal: true

# CORS for /api, /api-docs and /mcp. /mcp grants only the origins in GRAPH_MEM_MCP_ALLOWED_ORIGINS,
# the same list the MCP transport's Origin check accepts (same-origin pages need no CORS). The
# transport itself sends no CORS headers.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Localhost on any port (covers OpenWebUI, dev servers, etc.)
    origins "localhost", "127.0.0.1", "::1",
            /\Ahttp:\/\/localhost(:\d+)?\z/,
            /\Ahttp:\/\/127\.0\.0\.1(:\d+)?\z/

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Total-Count X-Page X-Per-Page],
      max_age: 86_400

    resource "/api-docs*",
      headers: :any,
      methods: %i[get options],
      max_age: 86_400
  end

  # LAN access: private network ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
  lan_192 = %r{\Ahttp://192\.168\.\d{1,3}\.\d{1,3}(:\d+)?\z}
  lan_10 = %r{\Ahttp://10\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\z}
  lan_172 = %r{\Ahttp://172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}(:\d+)?\z}

  allow do
    origins lan_192, lan_10, lan_172

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Total-Count X-Page X-Per-Page],
      max_age: 86_400

    resource "/api-docs*",
      headers: :any,
      methods: %i[get options],
      max_age: 86_400
  end

  # MCP: the transport's own allowlist (OfficialMcp::Transports.allowed_origins), checked per request.
  allow do
    origins ->(source, _env) { GraphMem::OfficialMcp::Transports.allowed_origin?(source) }

    resource "/mcp/*",
      headers: :any,
      methods: %i[get post delete options],
      expose: %w[Mcp-Session-Id],
      max_age: 86_400
  end
end
