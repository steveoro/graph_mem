# frozen_string_literal: true

require "rails_helper"

# F-3b step B: the baseline report's JSON shape (schema_version 1), from a synth run with the stub
# backend. A later, separate tool compares these reports with another graph, so a key added,
# renamed or removed here needs a new SCHEMA_VERSION.
RSpec.describe GraphMem::ScanProfile::Report, "schema_version 1" do
  include LlmSpecHelpers

  self.use_transactional_tests = false

  let(:manifest) { GraphMem::ScanProfile::Manifest.load }
  let(:stub) do
    FakeProvider.new do |prompt, **|
      GraphMem::ScanProfile::SynthRepo.stub_answer(prompt.to_s).merge(ok: true, error: nil, latency_ms: 1.0, prompt_tokens: 100)
    end
  end

  let(:top) { %w[schema_version graph_mem_version started_at options backend errors sweep runs] }
  let(:run_keys) { %w[repo commit profile settings caps files scans metrics graph] }
  let(:scan_keys) do
    %w[entities_created entities_updated observations_created observations_obsoleted observations_moved relations_created
       relations_deleted parts_total parts_failed files_too_large files_over_budget partial fallback fallback_reason status wall_s
       noise_dropped requests parts_split part_p50_s part_p95_s errors]
  end
  let(:metric_keys) do
    %w[entities entities_without_observations observations short_observations duplicate_observations generic_names
       filename_names root_only_entities isolated_entities types recall precision unexpected missed rescan_churn]
  end

  it "keeps the report's keys, and the graph as entities with type, observations and relations by name" do
    report = Dir.mktmpdir("scan-profile-shape") do |dir|
      options = GraphMem::ScanProfile::Options.parse({ "REPOS" => "synth", "PROFILE" => "docs", "REPORT_DIR" => dir }, manifest: manifest)
      written = with_llm_provider(stub) { GraphMem::ScanProfile::Runner.new(options: options, manifest: manifest, out: nil).call }
      JSON.parse(File.read(File.join(written.dir, "report.json")))
    end

    expect(described_class::SCHEMA_VERSION).to eq(1)
    expect(report.keys).to eq(top)
    expect(report["options"].keys).to eq(%w[repos profiles rescan full sweep settings])
    expect(report["backend"].keys).to eq(%w[chain cloud_chain left_machine model num_ctx llm_usage enqueued_jobs database database_kept])
    run = report["runs"].sole
    expect(run.keys).to eq(run_keys)
    expect(run["scans"].keys).to eq(%w[initial rescan])
    expect(run["scans"].values.map(&:keys)).to all(match_array(scan_keys))
    expect(run["metrics"].keys).to match_array(metric_keys)
    expect(run["graph"]).to all(match("name" => be_a(String), "type" => be_a(String), "observations" => all(be_a(String)),
                                      "relations" => all(match("type" => be_a(String), "to" => be_a(String)))))
    expect(run["graph"].first).to include("name" => "Gadget Project", "type" => "Project")
  end
end
