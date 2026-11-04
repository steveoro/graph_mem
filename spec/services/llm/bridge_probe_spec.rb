# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step T: Llm::BridgeProbe against the stub bridge. It keeps booleans, the gate
# result and short strings only: never a path, the token or a field it doesn't know.
RSpec.describe Llm::BridgeProbe do
  let(:health) do
    { bridge_version: "1.0.0",
      profiles: {
        claude: { cli_ok: true, cli_realpath: "/path/to/zq7/claude", cli_version: "0.0.0-fake (Fake CLI)",
                  gate: { result: "PASS", cli_version: "0.0.0-fake", wrapper_digest: "ab" * 32, models: [ "zq7-model" ], passed_on: "2026-11-04" },
                  gate_ok: true, tripped: false },
        devin: { cli_ok: false, cli_realpath: nil, cli_version: nil, gate: { result: "WARN", passed_on: "/path/to/zq7" }, gate_ok: false, tripped: true },
        "Bad Name" => { cli_ok: true }, "/path/to/zq7" => { cli_ok: true }, zq7list: [ 1 ]
      } }
  end
  let(:handler) { ->(_request) { [ 200, health ] } }
  let!(:stub) { start_bridge_stub { |request| handler.call(request) } }

  it "reports reachability and each profile's CLI, gate and tripped state, and nothing else" do
    probe = described_class.call

    expect(probe).to eq(configured: true, reason: nil, reachable: true, bridge_version: "1.0.0", profiles: {
                          "claude" => { cli_ok: true, gate_ok: true, gate_result: "PASS", passed_on: "2026-11-04", tripped: false },
                          "devin" => { cli_ok: false, gate_ok: false, gate_result: "other", passed_on: nil, tripped: true }
                        })
    expect(probe.inspect).not_to include("/path/to", bridge_token, "wrapper_digest", "zq7-model")
    expect(stub.requests.sole).to have_attributes(method: "GET", path: "/v1/health")
  end

  it "says why when not configured, without a request" do
    ENV["LLM_BRIDGE_URL"] = ""

    expect(described_class.call).to eq(configured: false, reason: "url_unset", reachable: false, bridge_version: nil, profiles: {})
    ENV["LLM_BRIDGE_URL"] = "http://localhost:#{stub.port}"
    expect(described_class.call[:reason]).to eq("url_invalid")
    expect(stub.requests).to be_empty
  end

  it "says why when the bridge refuses or isn't there, and drops a malformed body" do
    allow(handler).to receive(:call).and_return([ 401, "" ])
    expect(described_class.call).to include(configured: true, reachable: false, reason: "bridge_unauthorized")

    allow(handler).to receive(:call).and_return([ 200, { bridge_version: "/path/to/zq7", profiles: [ "claude" ] } ])
    expect(described_class.call).to include(reachable: true, bridge_version: nil, profiles: {})

    stub.stop
    expect(described_class.call).to include(reachable: false, reason: "bridge_unreachable")
  end
end
