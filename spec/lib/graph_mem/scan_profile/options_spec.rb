# frozen_string_literal: true

require "rails_helper"

# F-3b step S: the task's options; unknown repos, profiles, chains and settings are refused.
RSpec.describe GraphMem::ScanProfile::Options do
  let(:manifest) { GraphMem::ScanProfile::Manifest.load }

  def parse(env = {}) = described_class.parse(env, manifest: manifest)

  it "defaults to every repo, both profiles, a rescan, first-run caps, local Ollama, no cloud and tmp/scan_profile" do
    options = parse

    expect(options).to have_attributes(repos: manifest.keys, profiles: %w[docs code], rescan: true, full: false, keep_db: false,
                                       chain: "ollama", allow_cloud: false, settings: {}, db: nil,
                                       report_dir: Rails.root.join("tmp/scan_profile").to_s)
    expect(options.cloud?).to be(false)
  end

  it "reads REPOS, PROFILE, RESCAN=0, FULL=1, KEEP_DB=1, DB, REPORT_DIR and SETTINGS" do
    options = parse("REPOS" => "synth, goggles_api", "PROFILE" => "docs", "RESCAN" => "0", "FULL" => "1", "KEEP_DB" => "1",
                    "DB" => "synth_scan_profile", "REPORT_DIR" => "/path/to/reports",
                    "SETTINGS" => "summary_model=synth-model; summary_num_ctx=16384")

    expect(options).to have_attributes(repos: %w[synth goggles_api], profiles: %w[docs], rescan: false, full: true, keep_db: true,
                                       db: "synth_scan_profile", report_dir: "/path/to/reports",
                                       settings: { "summary_model" => "synth-model", "summary_num_ctx" => "16384" })
  end

  it "takes a cloud chain only as a known chain value, and allows cloud only with ALLOW_CLOUD=1" do
    expect(parse("BACKEND" => "claude,ollama")).to have_attributes(chain: "claude,ollama", allow_cloud: false)
    expect(parse("BACKEND" => "claude,ollama").cloud?).to be(true)
    expect(parse("BACKEND" => "agent_cli", "ALLOW_CLOUD" => "1").allow_cloud).to be(true)
    expect { parse("BACKEND" => "openai") }.to raise_error(described_class::Error, /isn't a scan chain/)
  end

  {
    "an unknown repo" => [ { "REPOS" => "synth,synth-private" }, /REPOS: unknown repo "synth-private"/ ],
    "a local folder as a repo" => [ { "REPOS" => "/path/to/graph_mem" }, /REPOS: unknown repo/ ],
    "an unknown profile" => [ { "PROFILE" => "tests" }, /PROFILE: unknown tests/ ],
    "the scan chain as a setting" => [ { "SETTINGS" => "llm_chain_scan=claude" }, /SETTINGS: "llm_chain_scan"/ ],
    "a budget setting" => [ { "SETTINGS" => "llm_budget_scan_calls=0" }, /SETTINGS/ ],
    "a non-model setting" => [ { "SETTINGS" => "enable_guest_access=true" }, /SETTINGS/ ],
    "a setting without a value" => [ { "SETTINGS" => "summary_model" }, /SETTINGS/ ]
  }.each do |label, (env, message)|
    it "refuses #{label}" do
      expect { parse(env) }.to raise_error(described_class::Error, message)
    end
  end
end
