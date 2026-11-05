# frozen_string_literal: true

require "rails_helper"

# F-3b step P: the profiler end to end, in process, with the stub backend (synth answers) and a
# real throwaway database. It writes nothing to the test database, so it runs outside a transaction.
RSpec.describe GraphMem::ScanProfile::Runner do
  include LlmSpecHelpers

  self.use_transactional_tests = false

  let(:manifest) { GraphMem::ScanProfile::Manifest.load }
  let(:stub) do
    FakeProvider.new do |prompt, **|
      GraphMem::ScanProfile::SynthRepo.stub_answer(prompt.to_s).merge(ok: true, error: nil, latency_ms: 1.0, prompt_tokens: 100)
    end
  end

  around do |example|
    Dir.mktmpdir("scan-profile-reports") do |dir|
      @report_dir = dir
      example.run
    end
  end

  def options(env = {})
    GraphMem::ScanProfile::Options.parse({ "REPOS" => "synth", "REPORT_DIR" => @report_dir }.merge(env), manifest: manifest)
  end

  def workspaces = Dir.glob(File.join(Dir.tmpdir, "#{GraphMem::ScanProfile::Workspace::PREFIX}*"))

  def database?(name)
    GraphMem::ScanProfile::Sandbox::AdminRecord.establish_connection(
      ActiveRecord::Base.connection_db_config.configuration_hash.except(:url, :database).merge(database: nil)
    )
    GraphMem::ScanProfile::Sandbox::AdminRecord.connection.select_value("SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '#{name}'").present?
  ensure
    GraphMem::ScanProfile::Sandbox::AdminRecord.remove_connection
  end

  def run(env = {}, fetcher: nil)
    described_class.new(options: options(env), manifest: manifest, fetcher: fetcher, out: StringIO.new).call
  end

  it "profiles synth (docs and code, initial and rescan) and writes the report; the test DB, the throwaway DB and the temp dirs are left as they were" do
    before_workspaces = workspaces
    before_entities = MemoryEntity.count

    report = with_llm_provider(stub) { run }

    json = JSON.parse(File.read(File.join(report.dir, "report.json")))
    expect(json).to include("schema_version" => 1, "graph_mem_version" => GraphMem::VERSION)
    expect(json["backend"]).to include("chain" => "ollama", "left_machine" => false, "database_kept" => false)
    expect(json["runs"].map { |run| [ run["repo"], run["profile"], run["scans"].keys ] })
      .to eq([ [ "synth", "docs", %w[initial rescan] ], [ "synth", "code", %w[initial rescan] ] ])
    code = json["runs"].last
    expect(code).to include("commit" => nil, "settings" => { "bytes_per_token" => 3.0, "chunk_output_tokens" => 2048, "max_chunks" => 16 },
                            "caps" => { "max_total_input_bytes" => 65_536, "max_files" => 20 })
    expect(code["scans"]["initial"]).to include("files_too_large" => 1, "partial" => true, "fallback" => false, "parts_split" => 1)
    expect(code["scans"]["initial"]["requests"]).to eq(code["scans"]["initial"]["parts_total"] + 1)
    expect(code["scans"]["initial"]["part_p50_s"]).to be_a(Float)
    expect(code["graph"].map { |entity| entity["name"] }).to include("Gadget Project", *GraphMem::ScanProfile::SynthRepo.expected("code")[:entities])
    expect(code["graph"].find { |entity| entity["name"] == "AlphaService" }["relations"]).to include({ "type" => "depends_on", "to" => "SynthWidget" })
    expect(code["metrics"]).to include("recall" => { "entities" => 1.0, "relations" => 1.0 }, "missed" => [], "rescan_churn" => be_a(Integer))
    expect(code["metrics"]["unexpected"]).to include("GeneratedSchema")

    texts = Dir.glob(File.join(report.dir, "*")).map { |path| File.read(path) }
    expect(texts.join).not_to include(Dir.tmpdir, Rails.root.to_s, Dir.home)
    expect(File.read(File.join(report.dir, "report.md"))).to include("| synth | code | 3.0 / 2048 / 16 | 64 KB / 20 | initial |", "## Noise (first scan)")
    expect(stub.calls).not_to be_empty
    expect(database?("#{ActiveRecord::Base.connection_db_config.database}_scan_profile")).to be(false)
    expect(workspaces).to eq(before_workspaces)
    expect(MemoryEntity.count).to eq(before_entities)
  end

  it "passes the per-repo caps to ProjectScanner.new: first-run caps, the scanner's own with FULL=1 and always for goggles_db" do
    fetcher = lambda do |url:, commit:, dir:|
      GraphMem::ScanProfile::SynthRepo.write(dir) && url && commit
    end
    allow(ProjectScanner).to receive(:new).and_call_original

    with_llm_provider(stub) { run({ "REPOS" => "goggles_api,goggles_db", "PROFILE" => "code", "RESCAN" => "0" }, fetcher: fetcher) }
    with_llm_provider(stub) { run({ "PROFILE" => "docs", "RESCAN" => "0", "FULL" => "1" }) }

    caps = ->(kwargs) { kwargs.slice(:max_total_input_bytes, :max_files, :project_name, :mode) }
    expect(ProjectScanner).to have_received(:new).with(hash_including(caps.call(max_total_input_bytes: 65_536, max_files: 20, project_name: "goggles_api", mode: "initial")))
    expect(ProjectScanner).to have_received(:new).with(hash_including(caps.call(max_total_input_bytes: nil, max_files: nil, project_name: "goggles_db", mode: "initial")))
    expect(ProjectScanner).to have_received(:new).with(hash_including(caps.call(max_total_input_bytes: nil, max_files: nil, project_name: "Gadget Project", mode: "initial")))
    expect(ProjectScanner).to have_received(:new).with(hash_including(file_globs: %w[app/api/**/*.rb]))
  end

  it "reports a repo whose pin can't be checked out, and goes on with the others" do
    moved = ->(url:, commit:, dir:) { raise GraphMem::ScanProfile::Workspace::CheckoutError, "synthetic: HEAD moved in #{dir}" if url && commit }

    report = with_llm_provider(stub) { run({ "REPOS" => "dry-inflector,synth", "PROFILE" => "docs", "RESCAN" => "0" }, fetcher: moved) }

    json = JSON.parse(File.read(File.join(report.dir, "report.json")))
    expect(json["errors"].sole).to include("repo" => "dry-inflector", "error" => a_string_matching(%r{\Asynthetic: HEAD moved in <path>/\S+/dry-inflector\z}))
    expect(json["errors"].sole["error"]).not_to include(Dir.tmpdir)
    expect(json["runs"].map { |run| run["repo"] }).to eq(%w[synth])
  end

  describe "a cloud chain" do
    let(:cloud) { FakeProvider.new(name: "agent_cli", cloud: true) { |prompt, **| GraphMem::ScanProfile::SynthRepo.stub_answer(prompt.to_s).merge(ok: true, error: nil, latency_ms: 1.0) } }

    around do |example|
      Llm::Registry.override(:agent_cli, cloud)
      example.run
    ensure
      Llm::Registry.reset_overrides!
    end

    it "is refused by the gate (the profiler's projects never allow cloud): nothing leaves the machine and the scan falls back" do
      report = run({ "BACKEND" => "agent_cli", "PROFILE" => "docs", "RESCAN" => "0" })

      json = JSON.parse(File.read(File.join(report.dir, "report.json")))
      expect(cloud.calls).to be_empty
      expect(json["backend"]).to include("chain" => "agent_cli", "cloud_chain" => true, "left_machine" => false)
      expect(json.dig("backend", "llm_usage", "scan", "agent_cli")).to include("calls" => 0, "refused" => be_positive)
      expect(json["runs"].sole["scans"]["initial"]).to include("fallback" => true)
      expect(File.read(File.join(report.dir, "report.md"))).to include("cloud chain: yes (refused by the gate); anything left the machine: no")
    end
  end
end
