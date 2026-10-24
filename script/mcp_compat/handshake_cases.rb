# frozen_string_literal: true

require "json"

# Loads and checks the MCP handshake cases in spec/fixtures/mcp/handshakes/ (mcp-update-plan PR-3).
# Plain Ruby (json only), shared by spec/requests/mcp_protocol_compat_spec.rb and
# script/mcp_compat/compare.rb. Every check is made on the wire: replies, status, headers, bodies.
#
#   McpCompat::HandshakeCases.load(:stdio)  # => [Hash, ...] (the "cases" array)
#   McpCompat::HandshakeCases.check_stdio(expectation, replies:, junk:)  # => [String] problems
#   McpCompat::HandshakeCases.check_http(expectation, response)          # => [String] problems
module McpCompat
  module HandshakeCases
    FIXTURE_DIR = File.expand_path("../../spec/fixtures/mcp/handshakes", __dir__)
    TARGETS = %w[graph_mem reference].freeze
    BASE_HEADERS = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }.freeze
    NEW_SESSION_VERSION = "2025-11-25"

    # A plain HTTP response: +status+ (Integer), +headers+ (lower-case names), +body+ (String).
    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    module_function

    # @param transport [Symbol, String] :stdio or :http
    # @return [Array<Hash>] the cases, read as UTF-8 whatever the locale
    def load(transport)
      JSON.parse(File.read(File.join(FIXTURE_DIR, "#{transport}.json"), encoding: "UTF-8")).fetch("cases")
    end

    # @return [String] one stdio line (no newline) for a `send` item
    def stdio_line(item)
      return [ item["raw_bytes_hex"] ].pack("H*") if item.is_a?(Hash) && item.key?("raw_bytes_hex")
      return item["raw"] if item.is_a?(Hash) && item.key?("raw")

      JSON.generate(item)
    end

    # @return [String] the request body bytes for an HTTP case's `request`
    def http_body(request)
      return [ request["body_hex"] ].pack("H*") if request.key?("body_hex")
      return request["body_raw"] if request.key?("body_raw")
      return JSON.generate(jsonrpc: "2.0", id: 39, method: "ping", params: { pad: "a" * request["body_pad_bytes"] }) if request.key?("body_pad_bytes")

      JSON.generate(request["body"])
    end

    # @return [String] the initialize body that opens a "new" session
    def initialize_body(id = 1)
      JSON.generate(jsonrpc: "2.0", id: id, method: "initialize",
                    params: { protocolVersion: NEW_SESSION_VERSION, capabilities: {}, clientInfo: { name: "mcp-compat", version: "0" } })
    end

    # Splits stdout lines into JSON-RPC 2.0 messages and anything else.
    # @return [Array(Array<Hash>, Array<String>)] [replies, junk lines]
    def parse_stdout(lines)
      lines.each_with_object([ [], [] ]) do |line, (replies, junk)|
        message = JSON.parse(line)
        message.is_a?(Hash) && message["jsonrpc"] == "2.0" ? replies << message : junk << line.chomp
      rescue JSON::ParserError
        junk << line.chomp
      end
    end

    # @return [Array<String>] what doesn't match a stdio expectation (empty when it all matches)
    def check_stdio(expectation, replies:, junk:)
      problems = []
      problems << "#{junk.size} non-JSON-RPC stdout line(s), first: #{junk.first[0, 120]}" if junk.any?
      problems << "#{replies.size} replies, want #{expectation['replies']}" if replies.size != expectation["replies"]

      null_id = replies.select { |reply| reply["id"].nil? }
      expectation["messages"].each do |want|
        got = want["id"].nil? ? null_id.shift : replies.find { |reply| reply["id"] == want["id"] }
        problems.concat(check_message(want, got, "id #{want['id'].inspect}"))
      end
      problems
    end

    # @param response [Response]
    # @return [Array<String>] what doesn't match an HTTP expectation (empty when it all matches)
    def check_http(expectation, response)
      problems = []
      problems << "status #{response.status}, want #{expectation['status']}" if response.status != expectation["status"]
      if expectation.key?("opens_session") && expectation["opens_session"] != !response.headers["mcp-session-id"].to_s.empty?
        problems << (expectation["opens_session"] ? "no Mcp-Session-Id" : "opened a session")
      end
      message = http_message(response)
      if expectation["empty_body"]
        problems << "body #{response.body[0, 120].inspect}, want none" unless response.body.strip.empty?
        return problems
      end
      problems << "id #{message&.dig('id').inspect}, want #{expectation['id'].inspect}" if expectation.key?("id") && message&.dig("id") != expectation["id"]
      problems.concat(check_message(expectation, message, "body"))
    end

    # The first JSON-RPC message of a JSON or SSE response body, or nil. SSE data lines without a
    # message (the empty priming event 2025-11-25 servers send first) are skipped.
    def http_message(response)
      text = response.body.to_s
      candidates = text.match?(/^data:/) ? text.scan(/^data: ?(.*)$/).flatten : [ text ]
      candidates.each do |candidate|
        parsed = JSON.parse(candidate)
        return parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        next
      end
      nil
    end

    # A comparable outline of what came back: status, ids, and result-or-error-code, not message text.
    def stdio_outline(replies)
      replies.map { |reply| [ reply["id"], reply.key?("error") ? reply.dig("error", "code") : "result" ] }
    end

    def http_outline(response)
      message = http_message(response)
      [ response.status, message&.dig("id"), message.nil? ? nil : (message.key?("error") ? message.dig("error", "code") : "result") ]
    end

    # @return [String] "same", "documented divergence", "graph_mem only" or "unexpected"
    def classify(kase, graph_mem_outline, reference_outline)
      return "graph_mem only" if kase.dig("expect", "reference").nil?
      return "same" if graph_mem_outline == reference_outline

      kase["divergence"] ? "documented divergence" : "unexpected"
    end

    def check_message(want, got, label)
      return [ "#{label}: no reply" ] if got.nil?
      return error_code_problems(want, got, label) if want.key?("error_code")
      return [] unless want.key?("result") || want.key?("result_has")

      result = got["result"]
      return [ "#{label}: error #{JSON.generate(got['error'])[0, 160]}, want a result" ] if result.nil?

      problems = []
      problems << "#{label}: result #{JSON.generate(result)[0, 160]} doesn't include #{JSON.generate(want['result'])}" if want.key?("result") && !subset?(want["result"], result)
      missing = Array(want["result_has"]).reject { |key| result.is_a?(Hash) && result.key?(key) }
      problems << "#{label}: result lacks #{missing.join(', ')}" if missing.any?
      problems
    end

    def error_code_problems(want, got, label)
      code = got.dig("error", "code")
      code == want["error_code"] ? [] : [ "#{label}: #{code ? "error #{code}" : 'a result'}, want error #{want['error_code']}" ]
    end

    # Recursive subset match: every key in +want+ must equal (or subset-match) the one in +got+.
    def subset?(want, got)
      return want == got unless want.is_a?(Hash)
      return false unless got.is_a?(Hash)

      want.all? { |key, value| got.key?(key) && subset?(value, got[key]) }
    end
  end
end
