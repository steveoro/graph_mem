# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step J: a cloud scan or judge answer is checked as JSON of the right shape, retried
# once on the same profile and model, then falls back to Ollama (never walking the backup models).
# The plan's spec table, one example per row, against the stub bridge.
RSpec.describe "Cloud JSON answers: shape, one retry, fall back" do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }
  let(:local) { FakeProvider.new(name: "ollama", result: { ok: true, text: '{"local": true}', error: nil, latency_ms: 1.0 }) }
  let(:queue) { [] }
  let!(:stub) do
    start_bridge_stub do |_request|
      text = queue.shift || '{"fallback": "bridge"}'
      [ 200, { ok: true, text: text, failure_class: nil } ]
    end
  end
  let(:object) { '{"architecture": [{"entity": {"name": "Zq7Part", "type": "Component"}}]}' }

  before do
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1"
    AppSettings.llm_profile_devin_model = "zq7-devin"
    AppSettings.llm_profile_devin_backup_models = "zq7-devin-b1"
  end

  after { AppSettings.clear_cache }

  def prompt = Llm::Prompt.new.trusted("Extract:\n").data("SynthWidget renders frames.").scoped(Llm::Scope.for_entities([ widget ]))

  def route(task, chain, answers, options: { format: "json", max_output_length: nil })
    queue.replace(answers)
    AppSettings.public_send(:"llm_chain_#{task}=", chain)
    with_llm_provider(local) { Llm::Router.generate(task, prompt, style: "concise", options: options) }
  end

  def models_sent = stub.requests.map { |request| request.json["model"] }

  it "accepts a fenced object in one attempt (scan, claude,ollama)" do
    expect(route(:scan, "claude,ollama", [ "```json\n#{object}\n```" ])).to include(ok: true, text: object, provider: "agent_cli")
    expect(models_sent).to eq([ "zq7-claude" ])
  end

  it "accepts prose around an object in one attempt (scan)" do
    expect(route(:scan, "claude,ollama", [ "Here it is: #{object} Thanks." ])).to include(ok: true, text: object)
    expect(stub.requests.size).to eq(1)
  end

  it "retries an array once, same model, with the same masked prompt plus the repair suffix (scan)" do
    lines = llm_usage_lines { expect(route(:scan, "claude,ollama", [ "[1, 2]", object ])).to include(ok: true, text: object) }

    first, second = stub.requests.map { |request| request.json["prompt"] }
    expect(models_sent).to eq(%w[zq7-claude zq7-claude])
    expect(second).to eq(first + Llm::CloudCall::REPAIR)
    expect(second).not_to include("[1, 2]")
    expect(lines.map { |line| line.values_at("outcome", "json", "retry", "fallback_step") }).to eq([ [ "error", "invalid", nil, 0 ], [ "ok", nil, 1, 0 ] ])
  end

  it "falls back to Ollama after two invalid answers, without trying the backup models (scan, claude,ollama)" do
    expect(route(:scan, "claude,ollama", [ "not json", "still not" ])).to include(ok: true, text: '{"local": true}', provider: "ollama")
    expect(models_sent).to eq(%w[zq7-claude zq7-claude])
  end

  it "fails as agent_cli_invalid_json with no fallback listed, and the scan part fails without a split (scan, claude)" do
    expect(route(:scan, "claude", [ "nope", "nope" ])).to include(ok: false, error: "agent_cli_invalid_json")

    queue.replace(Array.new(8, "nope"))
    chunks = [ ProjectScanner::ChunkPlanner::Chunk.new(index: 1, files: [], pieces: [ "--- FILE: a.rb\na\nb\n---\n", "--- FILE: b.rb\nc\n---\n" ],
                                                       estimated_tokens: 1) ]
    stub.requests.clear
    outcome = ProjectScanner::ChunkedExtraction.new(chunks: chunks, project_name: "Gadget Project", num_ctx: 8192, num_predict: 2048, timeout: 30,
                                                    llm_scope: Llm::Scope.for_entities([ widget ])).call
    expect(outcome).to have_attributes(parts_total: 1, parts_failed: 1, first_error: "agent_cli_invalid_json")
    expect(stub.requests.size).to eq(2)
  end

  it "accepts an object wrapping one array (judge, devin,ollama)" do
    text = '{"verdicts": [{"id": 1, "verdict": "kept"}], "note": "zq7"}'

    expect(route(:judge, "devin,ollama", [ text ], options: { format: "json" })).to include(ok: true, text: text, provider: "agent_cli")
  end

  it "falls back to Ollama after a scalar twice (judge, devin,ollama)" do
    expect(route(:judge, "devin,ollama", [ '"ok"', "42" ], options: { format: "json" })).to include(provider: "ollama")
    expect(models_sent).to eq(%w[zq7-devin zq7-devin])
  end

  it "accepts a 12,000-character array uncut (judge, devin)" do
    text = JSON.generate(Array.new(200) { |i| { id: i, verdict: "kept", reason: "Zq7 #{'x' * 40}" } })
    expect(text.length).to be > 12_000

    expect(route(:judge, "devin", [ text ], options: { format: "json" })).to include(ok: true, text: text)
  end

  it "leaves an Ollama answer unchecked and unretried (ollama)" do
    bad = FakeProvider.new(name: "ollama", result: { ok: true, text: "not json", error: nil, latency_ms: 1.0 })
    AppSettings.llm_chain_scan = "ollama"

    expect(with_llm_provider(bad) { Llm::Router.generate(:scan, prompt, style: "concise", options: { format: "json" }) }).to include(ok: true, text: "not json")
    expect(bad.calls.size).to eq(1)
    expect(stub.requests).to be_empty
  end

  it "falls back to Ollama when a valid answer can't be restored, never retried (scan, claude,ollama)" do
    leftover = '{"architecture": [{"entity": {"name": "⟦ENT_ffff⟧", "type": "Component"}}]}'

    expect(route(:scan, "claude,ollama", [ leftover ])).to include(ok: true, provider: "ollama")
    expect(stub.requests.size).to eq(1)
  end
end
