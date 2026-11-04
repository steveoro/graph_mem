# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step P: a scan's parts sent to agent_cli over the stub bridge. A bridge 400 never
# splits a part (only a 413 does), and a gate failure falls through to Ollama in an agent_cli,ollama
# chain. Temp dirs, synthetic files and answers, a FakeProvider in place of Ollama.
RSpec.describe ProjectScanner::ChunkedExtraction do
  around do |example|
    Dir.mktmpdir("chunked_bridge") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }
  let(:bridge) { ->(_request) { [ 200, { ok: true, text: answer, failure_class: nil } ] } }
  let!(:stub) { start_bridge_stub { |request| bridge.call(request) } }
  let(:local) { FakeProvider.new(name: "ollama") { |*| { ok: true, text: answer, error: nil, latency_ms: 1.0, done_reason: "stop", prompt_tokens: 10 } } }

  before do
    AppSettings.clear_cache
    AppSettings.llm_agent_cli_profile = "claude"
    AppSettings.llm_agent_cli_model = "zq7-model"
    project.update!(cloud_allowed: true, cloud_root: @root)
  end

  after { AppSettings.clear_cache }

  def answer = { architecture: [ { entity: { name: "Zq7Part", type: "Component" }, observations: [ "Zq7Part exists." ], relations: [] } ] }.to_json

  def chunk(index, *pieces) = ProjectScanner::ChunkPlanner::Chunk.new(index: index, files: [], pieces: pieces, estimated_tokens: 1)

  def block(name) = "--- FILE: #{name}\n#{name} line 1\n#{name} line 2\n---\n"

  def run(chunks)
    scope = Llm::Scope.for_scan(project_root: @root, project_name: "Gadget Project")
    with_llm_provider(local) do
      described_class.new(chunks: chunks, project_name: "Gadget Project", num_ctx: 8192, num_predict: 2048, timeout: 120, llm_scope: scope).call
    end
  end

  def parts = [ chunk(1, block("a.rb"), block("b.rb")), chunk(2, block("c.rb"), block("d.rb")), chunk(3, block("e.rb")) ]

  it "sends the parts to the bridge, masked, when agent_cli leads the scan chain" do
    AppSettings.llm_chain_scan = "agent_cli"

    outcome = run(parts)

    expect(outcome).to have_attributes(parts_total: 3, parts_done: 3, parts_failed: 0)
    expect(stub.requests.map { |request| request.json["task"] }).to all(eq("scan"))
    expect(stub.requests.map { |request| request.json["prompt"] }.join).not_to include("Gadget Project")
    expect(local.calls).to be_empty
  end

  it "never splits a part for a bridge 400: each part fails once, then the rest are skipped as an outage" do
    AppSettings.llm_chain_scan = "agent_cli"
    allow(bridge).to receive(:call).and_return([ 400, { ok: false, failure_class: "bridge_bad_request" } ])

    outcome = run(parts)

    expect(stub.requests.size).to eq(2)
    expect(stub.requests.map { |request| request.json["prompt"] }.join).not_to include("(half")
    expect(outcome).to have_attributes(parts_total: 3, parts_done: 0, parts_failed: 3, first_error: "bridge_bad_request", data: nil)
  end

  it "splits a part once for a bridge 413, as for Ollama" do
    AppSettings.llm_chain_scan = "agent_cli"
    tries = 0
    allow(bridge).to receive(:call) do
      (tries += 1) == 1 ? [ 413, { ok: false, failure_class: "prompt_too_long" } ] : [ 200, { ok: true, text: answer } ]
    end

    outcome = run(parts.first(1))

    expect(stub.requests.size).to eq(3)
    expect(stub.requests.drop(1).map { |request| request.json["prompt"][/This is part \d+ of \d+/] }).to eq([ "This is part 1 of 2", "This is part 2 of 2" ])
    expect(outcome).to have_attributes(parts_total: 2, parts_done: 2, parts_failed: 0)
  end

  it "answers from Ollama when the gate is stale and the chain is agent_cli,ollama" do
    AppSettings.llm_chain_scan = "agent_cli,ollama"
    allow(bridge).to receive(:call).and_return([ 503, { ok: false, failure_class: "gate_stale" } ])

    outcome = run(parts)

    expect(outcome).to have_attributes(parts_total: 3, parts_done: 3, parts_failed: 0)
    expect(stub.requests.size).to eq(3)
    expect(local.calls.size).to eq(3)
    expect(local.calls.map(&:prompt).join).to include("Gadget Project")
  end

  it "stops on tool use without splitting or falling through" do
    AppSettings.llm_chain_scan = "agent_cli,ollama"
    allow(bridge).to receive(:call).and_return([ 200, { ok: false, failure_class: "cli_tool_use" } ])

    outcome = run(parts)

    expect(outcome).to have_attributes(parts_failed: 3, first_error: "agent_cli_tool_use")
    expect(stub.requests.size).to eq(2)
    expect(local.calls).to be_empty
  end
end
