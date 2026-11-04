# frozen_string_literal: true

require "rails_helper"
require "rake"

# Agent-CLI PR5, step G: the probe lists each chain's configured profiles and models and flags a
# model the gate didn't test (the health body's gate.models), with the same single request.
RSpec.describe "Llm::BridgeProbe configured models", type: :request do
  let(:health) do
    { bridge_version: "1.0.0",
      profiles: { claude: { cli_ok: true, gate: { result: "PASS", models: [ "zq7-claude" ], passed_on: "2026-11-04" }, gate_ok: true, tripped: false },
                  devin: { cli_ok: true, gate: nil, gate_ok: false, tripped: false } } }
  end
  let!(:stub) { start_bridge_stub { [ 200, health ] } }

  before do
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1"
    AppSettings.llm_profile_devin_model = "zq7-devin"
    AppSettings.llm_chain_scan = "claude,devin,ollama"
  end

  after { AppSettings.clear_cache }

  it "lists primary and backups per chain, tested or not, and leaves the PR4 result alone without chains:" do
    probe = Llm::BridgeProbe.call(chains: true)

    expect(probe[:chains]).to eq("scan" => [ { profile: "claude", model: "zq7-claude", tested: true },
                                             { profile: "claude", model: "zq7-claude-b1", tested: false },
                                             { profile: "devin", model: "zq7-devin", tested: nil } ])
    expect(stub.requests.size).to eq(1)
    expect(Llm::BridgeProbe.call).not_to have_key(:chains)
  end

  it "lists the configured models with tested: nil when the bridge can't be asked" do
    stub.stop

    expect(Llm::BridgeProbe.call(chains: true)[:chains]["scan"].map { |entry| entry[:tested] }).to eq([ nil, nil, nil ])
  end

  it "shows them on the panel, flagging the untested backup, and in the rake task" do
    sign_in_operator
    post system_bridge_probe_path
    chains = Nokogiri::HTML(response.body).at_css("[data-testid='bridge-probe-chain-scan']").text.squish
    expect(chains).to eq("scan chain: claude zq7-claude claude zq7-claude-b1 not tested by the gate devin zq7-devin")

    Rails.application.load_tasks unless Rake::Task.task_defined?("environment")
    Rake::Task["llm:bridge_probe"].clear if Rake::Task.task_defined?("llm:bridge_probe")
    load Rails.root.join("lib/tasks/llm.rake")
    expect { Rake::Task["llm:bridge_probe"].invoke }.to output(/  chain scan: claude zq7-claude, claude zq7-claude-b1 \(NOT TESTED\), devin zq7-devin\n\z/).to_stdout
  end
end
