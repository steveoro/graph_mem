# frozen_string_literal: true

require "net/http"

module Llm
  # HTTP to the host bridge (agent-CLI PR4; the bridge is script/llm_bridge/, PR3). Plain Net::HTTP to
  # the literal `http://127.0.0.1:<port>` in LLM_BRIDGE_URL, no proxy, no redirect, no retry. The
  # token is read on every request from LLM_BRIDGE_TOKEN_FILE (opened with O_NOFOLLOW: a regular
  # file owned by the app's uid, no group or other bits, at least 32 bytes) and only ever sent in
  # the X-GM-Bridge-Token header: never logged, kept, or put in an error.
  #
  # Every bridge outcome becomes the provider result Hash (docs/summarization.md, "LLM providers"),
  # and the only `http_status` it ever carries is 413, so a bridge 400 can't make a scan part split.
  #
  #   client = Llm::BridgeClient.new
  #   client.configured?  # => false, client.reason # => "url_unset"
  #   client.complete("…", profile: "claude", model: "zq7-model", task: :scan, timeout_s: 120)
  #   # => { ok: true, text: "…", error: nil, latency_ms: 812.4 }
  #   # => { ok: false, text: nil, error: "bridge_gate_stale", latency_ms: 3.1 }
  class BridgeClient
    URL_PATTERN = %r{\Ahttp://127\.0\.0\.1:(\d{1,5})/?\z}
    DEFAULT_TOKEN_FILE = "~/.local/state/agent-cli/bridge.token"
    TOKEN_MIN_BYTES = 32
    TOKEN_MAX_BYTES = 4096
    MAX_BODY = 1024 * 1024
    OPEN_TIMEOUT_S = 2
    # The read timeout is the CLI's timeout plus this margin (the bridge's own gate check and spawn).
    READ_MARGIN_S = 10
    HEALTH_READ_TIMEOUT_S = 30
    # PR5: within a deadline (an inline call), the connect timeout, and the time left for the
    # bridge's own checks and spawn between the CLI's timeout and the read timeout.
    DEADLINE_OPEN_S = 1
    DEADLINE_MARGIN_S = 3
    TIMEOUTS = (1..600)
    # Bridge request errors by status (the body's class is not trusted for these).
    STATUS_ERRORS = { 400 => "bridge_bad_request", 401 => "bridge_unauthorized", 404 => "bridge_not_found",
                      405 => "bridge_method_not_allowed", 429 => "bridge_busy", 500 => "bridge_error" }.freeze
    GATE_CLASSES = %w[cli_missing gate_missing gate_failed gate_stale tripped].freeze
    # The CLI-level classes a 200 may carry (script/llm_bridge/profile_schema.py CLASSES, but
    # cli_missing, which is a 503, and prompt_too_long, which is a 413). Any other is a bad response.
    CLI_CLASSES = %w[cli_tool_use cli_tool_denied cli_timeout cli_quota cli_rate_limited cli_auth cli_model_unavailable
                     cli_payment_required cli_config cli_sandbox cli_truncated cli_turn_limit cli_error cli_bad_output].freeze
    TOOL_USE = "agent_cli_tool_use"
    PROMPT_TOO_LONG = "prompt_too_long"
    UNREACHABLE = "bridge_unreachable"
    BAD_RESPONSE = "bridge_bad_response"
    NOT_CONFIGURED = "bridge_not_configured"
    # Failures the chain moves on from (Llm::Router): every bridge or CLI failure but a too-long
    # prompt (returned, so a scan part splits) and tool use (never hidden by another provider).
    STAYS = [ PROMPT_TOO_LONG, TOOL_USE ].freeze

    # Raised internally for an answer that doesn't fit the contract (never leaves this class).
    class BadResponse < StandardError; end

    # @param result [Hash] a result from #complete
    # @return [Boolean] whether the Router should try the next provider in the chain
    def self.fall_through?(result)
      return false if result[:ok]

      failure?(result[:error]) && STAYS.exclude?(result[:error].to_s)
    end

    # @param error [String, nil] a result's error
    # @return [Boolean] whether it is a bridge or agent CLI failure (never one a split could fix;
    #   a too-long prompt is "prompt_too_long" with http_status 413)
    def self.failure?(error)
      error.to_s.start_with?("bridge_", "agent_cli_")
    end

    # @param env [#[]] where LLM_BRIDGE_URL and LLM_BRIDGE_TOKEN_FILE are read (ENV)
    def initialize(env: ENV)
      @env = env
    end

    # @return [Boolean] a valid URL and a safe token file
    def configured?
      reason.nil?
    end

    # @return [String, nil] why the client isn't configured: "url_unset", "url_invalid" or
    #   "token_file_unsafe"; nil when it is
    def reason
      return "url_unset" if @env["LLM_BRIDGE_URL"].blank?
      return "url_invalid" unless port
      return "token_file_unsafe" unless token

      nil
    end

    # @param prompt [String] the (masked) prompt text
    # @param profile [String] the bridge profile name
    # @param model [String]
    # @param task [Symbol, String] one of Llm::Router::TASKS (the bridge logs it)
    # @param timeout_s [Integer, nil] the CLI's timeout, clamped to 1..600
    # @param deadline_s [Integer, nil] PR5: the most seconds the whole call may take (connect, the
    #   bridge's checks and the CLI); the connect and read timeouts and the CLI's timeout_s are fitted
    #   inside it. nil: timeout_s plus the usual margins
    # @return [Hash] `{ ok:, text:, error:, latency_ms: }`, plus `done_reason: "length"` for a cut
    #   answer and `http_status: 413` for a too-long prompt; never raises
    def complete(prompt, profile:, model:, task:, timeout_s:, deadline_s: nil)
      started = clock
      seconds, open, read = call_times(timeout_s, deadline_s)
      body = JSON.generate(profile: profile.to_s, model: model.to_s, prompt: prompt.to_s, timeout_s: seconds,
                           task: task.to_s, run_id: SecureRandom.uuid)
      secret = token
      return failure(NOT_CONFIGURED, started) unless port && secret
      return failure(PROMPT_TOO_LONG, started, http_status: 413) if body.bytesize > MAX_BODY

      response = post("/v1/complete", body, secret, read_timeout: read, open_timeout: open)
      result_for(response, started)
    rescue BadResponse, JSON::ParserError
      failure(BAD_RESPONSE, started)
    rescue SystemCallError, IOError, Timeout::Error, SocketError, Net::HTTPBadResponse, Net::ProtocolError
      failure(UNREACHABLE, started)
    rescue StandardError
      failure("bridge_error", started)
    end

    # GET /v1/health.
    # @return [Hash] `{ ok: true, body: Hash }`, or `{ ok: false, error: String }` (one of this class's
    #   error names; never a message)
    def health
      secret = token
      return { ok: false, error: NOT_CONFIGURED } unless port && secret

      response = request(Net::HTTP::Get.new("/v1/health"), secret, read_timeout: HEALTH_READ_TIMEOUT_S)
      return { ok: false, error: STATUS_ERRORS.fetch(response.code.to_i, BAD_RESPONSE) } unless response.code == "200"

      { ok: true, body: parse(response) }
    rescue BadResponse, JSON::ParserError
      { ok: false, error: BAD_RESPONSE }
    rescue SystemCallError, IOError, Timeout::Error, SocketError, Net::HTTPBadResponse, Net::ProtocolError
      { ok: false, error: UNREACHABLE }
    rescue StandardError
      { ok: false, error: "bridge_error" }
    end

    private

    # @return [Integer, nil] the port of a valid LLM_BRIDGE_URL
    def port
      match = URL_PATTERN.match(@env["LLM_BRIDGE_URL"].to_s)
      number = match && match[1].to_i
      number if number&.between?(1, 65_535)
    end

    # @return [String, nil] the token when the file is safe; nil otherwise (never raises)
    def token
      path = File.expand_path(@env["LLM_BRIDGE_TOKEN_FILE"].presence || DEFAULT_TOKEN_FILE)
      # NONBLOCK: a FIFO at the path must not hang the open (the regular-file check then refuses it).
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        next nil unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?

        value = file.read(TOKEN_MAX_BYTES + 1).to_s.strip
        value if value.bytesize.between?(TOKEN_MIN_BYTES, TOKEN_MAX_BYTES) && value.match?(/\A[\x21-\x7e]+\z/)
      end
    rescue SystemCallError, IOError, ArgumentError
      nil
    end

    # @return [Array(Integer, Integer, Integer)] the CLI's timeout_s, the open and the read timeout
    def call_times(timeout_s, deadline_s)
      seconds = timeout_s.to_i.clamp(TIMEOUTS.min, TIMEOUTS.max)
      return [ seconds, OPEN_TIMEOUT_S, seconds + READ_MARGIN_S ] unless deadline_s

      read = [ deadline_s.to_i - DEADLINE_OPEN_S, 1 ].max
      [ seconds.clamp(TIMEOUTS.min, [ read - DEADLINE_MARGIN_S, TIMEOUTS.min ].max), DEADLINE_OPEN_S, read ]
    end

    def post(path, body, secret, read_timeout:, open_timeout: OPEN_TIMEOUT_S)
      request(Net::HTTP::Post.new(path, "Content-Type" => "application/json").tap { |post| post.body = body }, secret,
              read_timeout: read_timeout, open_timeout: open_timeout)
    end

    def request(http_request, secret, read_timeout:, open_timeout: OPEN_TIMEOUT_S)
      http_request["X-GM-Bridge-Token"] = secret
      http = Net::HTTP.new("127.0.0.1", port, nil) # nil: never a proxy from the environment
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.write_timeout = read_timeout
      http.max_retries = 0
      http.start { |connection| connection.request(http_request) }
    end

    def parse(response)
      body = JSON.parse(response.body.to_s)
      raise BadResponse unless body.is_a?(Hash)

      body
    end

    def result_for(response, started)
      status = response.code.to_i
      return failure(PROMPT_TOO_LONG, started, http_status: 413) if status == 413
      return failure(STATUS_ERRORS.fetch(status), started) if STATUS_ERRORS.key?(status)
      return gate_failure(parse(response), started) if status == 503
      raise BadResponse unless status == 200

      answer(parse(response), started)
    end

    def gate_failure(body, started)
      raise BadResponse unless GATE_CLASSES.include?(body["failure_class"])

      failure("bridge_#{body['failure_class']}", started)
    end

    def answer(body, started)
      if body["ok"] == true
        raise BadResponse unless body["text"].is_a?(String) && body["text"].present?

        return { ok: true, text: body["text"], error: nil, latency_ms: elapsed(started) }
      end
      klass = body["failure_class"].to_s
      raise BadResponse unless body["ok"] == false && CLI_CLASSES.include?(klass)

      error = "agent_cli_#{klass.delete_prefix('cli_')}"
      klass == "cli_truncated" ? failure(error, started, done_reason: "length") : failure(error, started)
    end

    def failure(error, started, **extra)
      { ok: false, text: nil, error: error, latency_ms: elapsed(started) }.merge(extra)
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def elapsed(started) = ((clock - started) * 1000).round(1)
  end
end
