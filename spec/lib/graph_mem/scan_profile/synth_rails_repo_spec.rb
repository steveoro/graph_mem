# frozen_string_literal: true

require "rails_helper"

# 1.75.0: the generated `synth_rails` engine, its stub answers, and a profiler run of it with the
# stub backend (the Rails code map's counters, both Badges as qualified role-typed entities, no bare
# Badge, no rescan churn). Like the runner spec, it runs outside a transaction (throwaway database).
RSpec.describe GraphMem::ScanProfile::SynthRailsRepo do
  include LlmSpecHelpers

  self.use_transactional_tests = false

  let(:manifest) { GraphMem::ScanProfile::Manifest.load }
  let(:stub) do
    FakeProvider.new do |prompt, **|
      repo = described_class.prompt?(prompt) ? described_class : GraphMem::ScanProfile::SynthRepo
      repo.stub_answer(prompt.to_s).merge(ok: true, error: nil, latency_ms: 1.0, prompt_tokens: 100)
    end
  end

  around { |example| Dir.mktmpdir("synth-rails-spec") { |dir| @dir = dir and example.run } }

  def profile(repos)
    options = GraphMem::ScanProfile::Options.parse({ "REPOS" => repos, "REPORT_DIR" => @dir }, manifest: manifest)
    report = with_llm_provider(stub) { GraphMem::ScanProfile::Runner.new(options: options, manifest: manifest, out: nil).call }
    @markdown = File.read(File.join(report.dir, "report.md"))
    JSON.parse(File.read(File.join(report.dir, "report.json")))["runs"]
  end

  it "writes a Rails engine the code map recognizes, with two Badges" do
    Dir.mktmpdir("synth-rails-tree") do |dir|
      described_class.write(dir)
      map = RailsCodeMap.build(dir, reserved_names: [ described_class::PROJECT_NAME ])

      expect(map.entry("GadgetEngine::Badge").type).to eq("Model")
      expect(map.entry("GadgetEngine::Importers::Badge").type).to eq("Strategy")
      expect(map.entry("GadgetEngine")).to be_nil
      expect(described_class.expected("code")[:entities]).to all(satisfy { |name| map.entry(name) })
    end
  end

  it "answers only for its own project's parts, by file" do
    prompt = ProjectScanner::ExtractionPrompt.text("--- FILE: Gemfile\ngem \"grape\"\n---\n", part: 1, parts: 1,
                                                   project_name: described_class::PROJECT_NAME)

    expect(described_class.prompt?(prompt)).to be(true)
    expect(GraphMem::ScanProfile::SynthRepo.stub_answer(prompt)[:text]).not_to include("grape")
    expect(JSON.parse(described_class.stub_answer(prompt)[:text])["architecture"].map { |item| item.dig("entity", "name") })
      .to eq(%w[grape mysql2])
  end

  it "profiles synth_rails: the skeleton's role-typed entities, mapped answers, no bare Badge and no rescan churn" do
    runs = profile("synth_rails")

    expect(runs.map { |run| run["profile"] }).to eq(%w[docs code])
    runs.each do |run|
      types = run["graph"].to_h { |entity| [ entity["name"], entity["type"] ] }
      expect(types).to include("GadgetEngine::Badge" => "Model", "GadgetEngine::Importers::Badge" => "Strategy",
                               "GadgetEngine::SwimmersController" => "Controller", "app/views/gadget_engine/swimmers" => "View")
      expect(types.keys).not_to include("Badge", "Swimmer", "SwimmersController")
      expect(run["scans"]["initial"]["code_map"]).to include("entities" => 15, "complete" => true, "entities_created" => 15)
      expect(run["metrics"]).to include("code_map_entities" => 15, "rescan_churn" => 0, "missed" => [])
      expect(run["metrics"]["recall"]).to eq("entities" => 1.0, "relations" => 1.0)
    end
    docs = runs.first
    expect(docs["graph"].find { |entity| entity["name"] == "grape" }["type"]).to eq("Gem")
    expect(docs["scans"]["initial"]["code_map"]).to include("items_dropped" => 1, "gems_typed" => 2)
    mapped = docs["scans"]["initial"]["code_map"]["items_mapped"]
    expect(@markdown).to include("| 15/#{mapped}/1 |")
  end

  it "leaves synth's numbers as they were: no code map" do
    run = profile("synth").last

    expect(run["scans"]["initial"]["code_map"]).to eq({})
    expect(run["metrics"]).to include("code_map_entities" => 0, "recall" => { "entities" => 1.0, "relations" => 1.0 })
  end
end
