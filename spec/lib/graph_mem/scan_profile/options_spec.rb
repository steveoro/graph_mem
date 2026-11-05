# frozen_string_literal: true

require "rails_helper"

# F-3b step S: the task's options; unknown repos, profiles, chains and settings are refused.
RSpec.describe GraphMem::ScanProfile::Options do
  let(:manifest) { GraphMem::ScanProfile::Manifest.load }

  def parse(env = {}) = described_class.parse(env, manifest: manifest)

  it "defaults to every repo, both profiles, a rescan, first-run caps, local Ollama and tmp/scan_profile" do
    options = parse

    expect(options).to have_attributes(repos: manifest.keys, profiles: %w[docs code], rescan: true, full: false, keep_db: false,
                                       chain: "ollama", settings: {}, db: nil,
                                       report_dir: Rails.root.join("tmp/scan_profile").to_s)
  end

  it "reads REPOS, PROFILE, RESCAN=0, FULL=1, KEEP_DB=1, DB, REPORT_DIR and SETTINGS" do
    options = parse("REPOS" => "synth, goggles_api", "PROFILE" => "docs", "RESCAN" => "0", "FULL" => "1", "KEEP_DB" => "1",
                    "DB" => "synth_scan_profile", "REPORT_DIR" => "/path/to/reports",
                    "SETTINGS" => "summary_model=synth-model; summary_num_ctx=16384")

    expect(options).to have_attributes(repos: %w[synth goggles_api], profiles: %w[docs], rescan: false, full: true, keep_db: true,
                                       db: "synth_scan_profile", report_dir: "/path/to/reports",
                                       settings: { "summary_model" => "synth-model", "summary_num_ctx" => "16384" })
  end

  it "reads SWEEP and runs every combination; without it, the current settings once" do
    options = parse("SWEEP" => "bytes_per_token:2.5,3.0,3.5; chunk_output_tokens:1024,2048; max_chunks:16,32")

    expect(options.sweep).to eq("bytes_per_token" => [ 2.5, 3.0, 3.5 ], "chunk_output_tokens" => [ 1024, 2048 ], "max_chunks" => [ 16, 32 ])
    expect(options.setting_sets.size).to eq(12)
    expect(options.setting_sets.first).to eq("bytes_per_token" => 2.5, "chunk_output_tokens" => 1024, "max_chunks" => 16)
    expect(options.setting_sets.uniq.size).to eq(12)
    expect(parse.setting_sets).to eq([ {} ])
  end

  it "runs on local Ollama only: BACKEND may name it, and a cloud chain is refused up front" do
    expect(parse("BACKEND" => "ollama").chain).to eq("ollama")
    (Llm::Router::CHAIN_VALUES - [ "ollama" ]).each do |chain|
      expect { parse("BACKEND" => chain) }.to raise_error(described_class::Error, /BACKEND=#{Regexp.escape(chain)} isn't available: .*only the Projects page grants/)
    end
    expect { parse("BACKEND" => "openai") }.to raise_error(described_class::Error, /isn't a scan chain/)
  end

  it "refuses ALLOW_CLOUD=1: only the Projects page grants cloud access" do
    expect { parse("ALLOW_CLOUD" => "1") }.to raise_error(described_class::Error, /ALLOW_CLOUD=1 isn't available: .*only the Projects page grants/)
  end

  {
    "an unknown repo" => [ { "REPOS" => "synth,synth-private" }, /REPOS: unknown repo "synth-private"/ ],
    "a local folder as a repo" => [ { "REPOS" => "/path/to/graph_mem" }, /REPOS: unknown repo/ ],
    "an unknown profile" => [ { "PROFILE" => "tests" }, /PROFILE: unknown tests/ ],
    "the scan chain as a setting" => [ { "SETTINGS" => "llm_chain_scan=claude" }, /SETTINGS: "llm_chain_scan"/ ],
    "a budget setting" => [ { "SETTINGS" => "llm_budget_scan_calls=0" }, /SETTINGS/ ],
    "a non-model setting" => [ { "SETTINGS" => "enable_guest_access=true" }, /SETTINGS/ ],
    "a setting without a value" => [ { "SETTINGS" => "summary_model" }, /SETTINGS/ ],
    "an unknown sweep setting" => [ { "SWEEP" => "validation_batch_size:5" }, /SWEEP: unknown setting "validation_batch_size"/ ],
    "a sweep value out of range" => [ { "SWEEP" => "max_chunks:16,99" }, /SWEEP: max_chunks value "99" must be a number in 1..64/ ],
    "a sweep value that isn't a number" => [ { "SWEEP" => "bytes_per_token:dense" }, /SWEEP: bytes_per_token value "dense"/ ],
    "a sweep setting without values" => [ { "SWEEP" => "max_chunks:" }, /SWEEP: max_chunks needs at least one value/ ]
  }.each do |label, (env, message)|
    it "refuses #{label}" do
      expect { parse(env) }.to raise_error(described_class::Error, message)
    end
  end
end
