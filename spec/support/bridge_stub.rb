# frozen_string_literal: true

require "socket"
require "json"

# Agent-CLI PR4: a stand-in for the host bridge (script/llm_bridge/bridge.py) on an ephemeral
# 127.0.0.1 port, in a thread. It records each request and answers with whatever the handler
# returns, so specs drive Llm::BridgeClient over real HTTP without a bridge, CLI or model.
#
#   stub = BridgeStub.start { |request| [ 200, { ok: true, text: "SynthWidget", failure_class: nil } ] }
#   stub.url                     # => "http://127.0.0.1:43123"
#   stub.requests.last.json      # => { "profile" => "claude", "model" => "zq7-model", … }
#   stub.stop
class BridgeStub
  # @!attribute method [String] "GET" or "POST"
  # @!attribute path [String]
  # @!attribute headers [Hash{String => String}] lower-cased names
  # @!attribute body [String]
  Request = Data.define(:method, :path, :headers, :body) do
    # @return [Hash, nil] the body as JSON, nil when it isn't
    def json
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
  end

  REASONS = { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 405 => "Method Not Allowed",
              413 => "Payload Too Large", 429 => "Too Many Requests", 500 => "Internal Server Error",
              503 => "Service Unavailable" }.freeze

  # @yieldparam request [Request]
  # @yieldreturn [Array(Integer, Object)] the status and the body (a Hash or Array is sent as JSON,
  #   a String as is); `[status, body, delay_s]` waits first
  # @return [BridgeStub] listening
  def self.start(&handler)
    new(handler).tap(&:listen)
  end

  # @return [Array<Request>]
  attr_reader :requests

  def initialize(handler)
    @handler = handler
    @requests = []
    @mutex = Mutex.new
  end

  # @return [void]
  def listen
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  # @return [String] the base URL
  def url = "http://127.0.0.1:#{port}"

  # @return [Integer]
  def port = @server.addr[1]

  # @return [void]
  def stop
    @thread&.kill
    @server&.close
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      socket = @server.accept
      Thread.new(socket) { |client| handle(client) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(socket)
    request = read_request(socket)
    @mutex.synchronize { @requests << request }
    status, body, delay = @handler.call(request)
    sleep(delay) if delay
    text = body.is_a?(String) ? body : JSON.generate(body)
    socket.write("HTTP/1.1 #{status} #{REASONS.fetch(status, 'Other')}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    method, path = socket.gets.to_s.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    Request.new(method: method, path: path, headers: headers, body: socket.read(headers["content-length"].to_i).to_s)
  end
end

# Spec helpers: point the app at a stub bridge with a fresh random token file.
module BridgeStubHelpers
  # Starts a stub, writes a 0600 token file in a temp dir, sets LLM_BRIDGE_URL and
  # LLM_BRIDGE_TOKEN_FILE for the block, and tears it all down after.
  #
  # @yieldparam request [BridgeStub::Request] (the handler, see BridgeStub.start)
  # @return [BridgeStub]
  def start_bridge_stub(&handler)
    stub = BridgeStub.start(&handler)
    dir = Dir.mktmpdir("bridge_stub")
    @bridge_token = "fake-#{SecureRandom.urlsafe_base64(32)}"
    path = File.join(dir, "bridge.token")
    File.write(path, @bridge_token)
    File.chmod(0o600, path)
    saved = ENV.to_h.slice("LLM_BRIDGE_URL", "LLM_BRIDGE_TOKEN_FILE")
    ENV["LLM_BRIDGE_URL"] = stub.url
    ENV["LLM_BRIDGE_TOKEN_FILE"] = path
    (@bridge_cleanups ||= []) << lambda do
      stub.stop
      %w[LLM_BRIDGE_URL LLM_BRIDGE_TOKEN_FILE].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
      FileUtils.remove_entry(dir)
    end
    stub
  end

  # @return [String] the random token of the running stub
  attr_reader :bridge_token
end

RSpec.configure do |config|
  config.include BridgeStubHelpers
  config.after { @bridge_cleanups&.reverse_each(&:call) }
end
