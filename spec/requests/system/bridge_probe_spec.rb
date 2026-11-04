# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step T: the "Host bridge" block in Settings › Summaries and its "Check now" button.
RSpec.describe "System › Settings › Host bridge", type: :request do
  let(:health) do
    { bridge_version: "1.0.0", profiles: { claude: { cli_ok: true, cli_realpath: "/path/to/zq7/claude", gate: { result: "PASS", passed_on: "2026-11-04" },
                                                     gate_ok: true, tripped: false } } }
  end

  def block = Nokogiri::HTML(response.body).at_css("[data-testid='settings-bridge-probe']")

  context "as the operator" do
    before { sign_in_operator }

    it "shows only 'not configured' while LLM_BRIDGE_URL is unset" do
      saved = ENV.delete("LLM_BRIDGE_URL")
      get system_settings_path(tab: "summaries")

      expect(block.text).to include("Host bridge", "Not configured")
      expect(block.at_css("form")).to be_nil
    ensure
      ENV["LLM_BRIDGE_URL"] = saved if saved
    end

    it "offers Check now, and shows what the bridge said, with no path or token, only after a POST" do
      stub = start_bridge_stub { [ 200, health ] }
      get system_settings_path(tab: "summaries")
      expect(block.text).to include("Not checked yet")
      expect(stub.requests).to be_empty

      post system_bridge_probe_path

      expect(response).to have_http_status(:ok)
      expect(block.at_css("[data-testid='bridge-probe-profile-claude']").text.squish).to eq("claude: CLI found, gate PASS (passed on 2026-11-04), usable.")
      expect(response.body).not_to include("/path/to/zq7", bridge_token)
      expect(stub.requests.size).to eq(1)
    end

    it "says why the bridge isn't usable" do
      start_bridge_stub { [ 401, "" ] }
      post system_bridge_probe_path

      expect(block.text).to include("Not usable: bridge_unauthorized.")
    end
  end

  it "refuses a guest (403) without asking the bridge" do
    stub = start_bridge_stub { [ 200, health ] }
    enable_guest!
    sign_in_guest
    post system_bridge_probe_path

    expect(response).to have_http_status(:forbidden)
    expect(stub.requests).to be_empty
  end
end
