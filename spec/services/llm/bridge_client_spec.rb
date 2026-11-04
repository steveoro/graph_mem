# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step C1: Llm::BridgeClient against an in-process stub bridge on 127.0.0.1. One
# example per row of the mapping table (docs/summarization.md), the URL and token-file rules, the
# timeouts and the size cap. Synthetic data, a random token, never a real bridge.
RSpec.describe Llm::BridgeClient do
  subject(:client) { described_class.new }

  let(:handler) { ->(_request) { [ 200, { ok: true, text: "SynthWidget renders frames.", failure_class: nil } ] } }
  let!(:stub) { start_bridge_stub { |request| handler.call(request) } }

  def complete(prompt = "Summarize Gadget Project.", **options)
    client.complete(prompt, profile: "claude", model: "zq7-model", task: :scan, timeout_s: 30, **options)
  end

  def answering(status, body) = ->(_request) { [ status, body ] }

  describe "configuration" do
    it "accepts only the literal http://127.0.0.1:<port>" do
      expect(client).to be_configured
      [ "http://localhost:#{stub.port}", "http://[::1]:#{stub.port}", "http://127.0.0.2:#{stub.port}", "https://127.0.0.1:#{stub.port}",
        "http://127.0.0.1:#{stub.port}/v1", "http://user:pw@127.0.0.1:#{stub.port}", "http://127.0.0.1:#{stub.port}?a=1",
        "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:70000", "http://zq7.example:#{stub.port}" ].each do |url|
        expect(described_class.new(env: ENV.to_h.merge("LLM_BRIDGE_URL" => url)).reason).to eq("url_invalid"), url
      end
      expect(described_class.new(env: ENV.to_h.except("LLM_BRIDGE_URL")).reason).to eq("url_unset")
      expect(described_class.new(env: ENV.to_h.merge("LLM_BRIDGE_URL" => "#{stub.url}/"))).to be_configured
    end

    it "refuses a missing, 0644, symlinked, foreign-owned, short or non-printable token file" do
      path = ENV.fetch("LLM_BRIDGE_TOKEN_FILE")
      dir = File.dirname(path)
      unsafe = lambda do |file|
        described_class.new(env: ENV.to_h.merge("LLM_BRIDGE_TOKEN_FILE" => file)).reason
      end

      expect(unsafe.call(File.join(dir, "missing"))).to eq("token_file_unsafe")
      File.symlink(path, File.join(dir, "link"))
      expect(unsafe.call(File.join(dir, "link"))).to eq("token_file_unsafe")
      { "open" => [ bridge_token, 0o644 ], "group" => [ bridge_token, 0o640 ], "short" => [ "fake-short", 0o600 ],
        "spaced" => [ "fake #{bridge_token}", 0o600 ] }.each do |name, (text, mode)|
        File.write(File.join(dir, name), text)
        File.chmod(mode, File.join(dir, name))
        expect(unsafe.call(File.join(dir, name))).to eq("token_file_unsafe"), name
      end
      File.mkfifo(File.join(dir, "fifo"), 0o600)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(unsafe.call(File.join(dir, "fifo"))).to eq("token_file_unsafe")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      allow_any_instance_of(File::Stat).to receive(:uid).and_return(Process.uid + 1) # rubocop:disable RSpec/AnyInstance
      expect(client.reason).to eq("token_file_unsafe")
    end

    it "sends nothing when not configured" do
      ENV["LLM_BRIDGE_URL"] = "http://localhost:#{stub.port}"

      expect(complete).to include(ok: false, error: "bridge_not_configured")
      expect(client.health).to eq(ok: false, error: "bridge_not_configured")
      expect(stub.requests).to be_empty
    end
  end

  describe "the request" do
    it "posts the six keys with the token header, a fresh UUID run id and the clamped timeout" do
      complete
      client.complete("Gadget Project", profile: "devin", model: "zq7-model", task: "judge", timeout_s: 9_999)
      client.complete("Gadget Project", profile: "devin", model: "zq7-model", task: :summary, timeout_s: nil)

      first, clamped, low = stub.requests.map(&:json)
      expect(first.keys).to contain_exactly("profile", "model", "prompt", "timeout_s", "task", "run_id")
      expect(first).to include("profile" => "claude", "model" => "zq7-model", "prompt" => "Summarize Gadget Project.", "timeout_s" => 30, "task" => "scan")
      expect(first["run_id"]).to match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/)
      expect(clamped).to include("timeout_s" => 600, "task" => "judge")
      expect(low["timeout_s"]).to eq(1)
      expect(stub.requests.map(&:path)).to all(eq("/v1/complete"))
      expect(stub.requests.map { |request| request.headers["x-gm-bridge-token"] }).to all(eq(bridge_token))
      expect(stub.requests.map { |request| request.json["run_id"] }.uniq.size).to eq(3)
    end

    it "sets a 2 s open timeout and the CLI timeout plus the margin as the read timeout, with no proxy or retry" do
      created = []
      allow(Net::HTTP).to receive(:new).and_wrap_original { |original, *args| original.call(*args).tap { |http| created << [ args, http ] } }
      complete

      args, http = created.sole
      expect(args).to eq([ "127.0.0.1", stub.port, nil ])
      expect([ http.open_timeout, http.read_timeout, http.max_retries ]).to eq([ 2, 40, 0 ])
      expect(http.proxy?).to be(false)
    end

    it "answers 413 for a body over 1 MiB without sending it" do
      result = complete("Zq7" * 400_000)

      expect(result).to include(ok: false, error: "prompt_too_long", http_status: 413)
      expect(stub.requests).to be_empty
    end

    it "gives up after the read timeout (bridge_unreachable)" do
      stub_const("Llm::BridgeClient::READ_MARGIN_S", 0)
      slow = answering(200, { ok: true, text: "late" })
      allow(handler).to receive(:call) { |request| [ *slow.call(request), 2 ] }

      expect(client.complete("Gadget", profile: "claude", model: "zq7-model", task: :scan, timeout_s: 1)).to include(ok: false, error: "bridge_unreachable")
    end
  end

  describe "the mapping table" do
    it "200 ok: true → ok with the text as sent, and a latency" do
      expect(complete).to include(ok: true, text: "SynthWidget renders frames.", error: nil)
      expect(complete[:latency_ms]).to be_a(Float)
    end

    it "200 ok: false cli_* → agent_cli_<class>, no http_status" do
      %w[cli_timeout cli_quota cli_rate_limited cli_auth cli_model_unavailable cli_error cli_bad_output cli_tool_denied].each do |klass|
        allow(handler).to receive(:call).and_return([ 200, { ok: false, text: nil, failure_class: klass } ])
        result = complete
        expect(result).to include(ok: false, text: nil, error: "agent_cli_#{klass.delete_prefix('cli_')}")
        expect(result).not_to have_key(:http_status)
        expect(described_class.fall_through?(result)).to be(true)
      end
    end

    it "200 cli_truncated → agent_cli_truncated with done_reason length" do
      allow(handler).to receive(:call).and_return([ 200, { ok: false, failure_class: "cli_truncated" } ])

      expect(complete).to include(ok: false, error: "agent_cli_truncated", done_reason: "length")
      expect(complete).not_to have_key(:http_status)
    end

    it "200 cli_tool_use → agent_cli_tool_use, which the chain never falls through" do
      allow(handler).to receive(:call).and_return([ 200, { ok: false, failure_class: "cli_tool_use" } ])

      expect(complete).to include(ok: false, error: "agent_cli_tool_use")
      expect(described_class.fall_through?(complete)).to be(false)
    end

    it "413 → prompt_too_long with http_status 413, returned (the scan splits)" do
      allow(handler).to receive(:call).and_return([ 413, { ok: false, failure_class: "prompt_too_long" } ])

      expect(complete).to include(ok: false, error: "prompt_too_long", http_status: 413)
      expect(described_class.fall_through?(complete)).to be(false)
    end

    it "400 / 404 / 405 → bridge_bad_request / bridge_not_found / bridge_method_not_allowed, never an http_status" do
      { 400 => "bridge_bad_request", 404 => "bridge_not_found", 405 => "bridge_method_not_allowed" }.each do |status, error|
        allow(handler).to receive(:call).and_return([ status, { ok: false, failure_class: "anything" } ])
        expect(complete).to include(ok: false, error: error)
        expect(complete).not_to have_key(:http_status)
      end
    end

    it "401 → bridge_unauthorized" do
      allow(handler).to receive(:call).and_return([ 401, "" ])

      expect(complete).to include(ok: false, error: "bridge_unauthorized")
    end

    it "429 → bridge_busy" do
      allow(handler).to receive(:call).and_return([ 429, { ok: false, failure_class: "bridge_busy" } ])

      expect(complete).to include(ok: false, error: "bridge_busy")
    end

    it "503 gate and tripped classes → bridge_<class>; an unknown 503 class → bridge_bad_response" do
      %w[cli_missing gate_missing gate_failed gate_stale tripped].each do |klass|
        allow(handler).to receive(:call).and_return([ 503, { ok: false, failure_class: klass } ])
        expect(complete).to include(ok: false, error: "bridge_#{klass}")
      end
      allow(handler).to receive(:call).and_return([ 503, { ok: false, failure_class: "zq7_other" } ])
      expect(complete).to include(error: "bridge_bad_response")
    end

    it "500 → bridge_error" do
      allow(handler).to receive(:call).and_return([ 500, { ok: false, failure_class: "bridge_error" } ])

      expect(complete).to include(ok: false, error: "bridge_error")
    end

    it "connection refused → bridge_unreachable" do
      stub.stop
      expect(complete).to include(ok: false, error: "bridge_unreachable")
    end

    it "non-JSON, a non-object, an unknown status or class, a blank ok text → bridge_bad_response" do
      [ [ 200, "not json" ], [ 200, [ 1 ] ], [ 302, { ok: true, text: "x" } ], [ 200, { ok: false, failure_class: "gate_stale" } ],
        [ 200, { ok: false, failure_class: "cli_tool_partly_hooked" } ], [ 200, { ok: false, failure_class: "cli_missing" } ],
        [ 200, { ok: "yes", text: "x" } ], [ 200, { ok: true, text: " " } ], [ 200, { ok: true, text: 42 } ] ].each do |status, body|
        allow(handler).to receive(:call).and_return([ status, body ])
        expect(complete).to include(ok: false, error: "bridge_bad_response"), body.inspect
      end
    end

    it "sets http_status only on the 413 row" do
      rows = [ [ 200, { ok: false, failure_class: "cli_error" } ], [ 400, {} ], [ 401, {} ], [ 404, {} ], [ 405, {} ], [ 429, {} ],
               [ 500, {} ], [ 503, { failure_class: "gate_stale" } ], [ 418, {} ], [ 413, {} ] ]
      statuses = rows.map do |status, body|
        allow(handler).to receive(:call).and_return([ status, body ])
        complete[:http_status]
      end

      expect(statuses).to eq([ nil ] * 9 + [ 413 ])
    end
  end

  describe "health" do
    it "gets /v1/health with the token and returns the body" do
      allow(handler).to receive(:call).and_return([ 200, { bridge_version: "1.0.0", profiles: {} } ])

      expect(client.health).to eq(ok: true, body: { "bridge_version" => "1.0.0", "profiles" => {} })
      expect(stub.requests.sole).to have_attributes(method: "GET", path: "/v1/health")
      expect(stub.requests.sole.headers["x-gm-bridge-token"]).to eq(bridge_token)
    end

    it "maps a refusal or no bridge to an error name" do
      allow(handler).to receive(:call).and_return([ 401, "" ])
      expect(client.health).to eq(ok: false, error: "bridge_unauthorized")
      stub.stop
      expect(client.health).to eq(ok: false, error: "bridge_unreachable")
    end
  end

  it "never puts the token in a log line, an error or a result" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    allow(Rails).to receive(:logger).and_return(logger)
    results = [ complete ]
    [ [ 401, "" ], [ 500, "boom" ], [ 200, "x" ] ].each do |row|
      allow(handler).to receive(:call).and_return(row)
      results << complete << client.health
    end
    allow(Net::HTTP).to receive(:new).and_raise(ArgumentError, "zq7")
    results << complete << client.health

    expect(results.map(&:inspect).join + output.string).not_to include(bridge_token)
    expect(results.last).to eq(ok: false, error: "bridge_error")
  end
end
