# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step B: daily cloud budgets per task. A MemoryStore stands in for the cache;
# travel_to only crosses a calendar day (no age is compared anywhere).
RSpec.describe Llm::Budget do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }
  let(:local) { FakeProvider.new(name: "ollama", result: { ok: true, text: "local answer", error: nil, latency_ms: 1.0 }) }
  let(:handler) { ->(_request) { [ 200, { ok: true, text: "bridge answer", failure_class: nil } ] } }
  let!(:stub) { start_bridge_stub { |request| handler.call(request) } }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1"
  end

  after { AppSettings.clear_cache }

  def prompt = Llm::Prompt.new.trusted("Summarize:\n").data("SynthWidget renders frames.").scoped(Llm::Scope.for_entities([ widget ]))

  def route(chain = "claude,ollama", task: :judge, options: nil)
    AppSettings.public_send(:"llm_chain_#{task}=", chain)
    with_llm_provider(local) { Llm::Router.generate(task, prompt, style: "concise", options: options) }
  end

  it "has no limit by default (0), and reads no counter for it" do
    allow(cache).to receive(:read).and_call_original
    3.times { expect(route).to include(text: "bridge answer") }

    expect(described_class.limits(:judge)).to eq(calls: 0, tokens: 0)
    expect(described_class.used(:judge)[:calls]).to eq(3)
    expect(cache).to have_received(:read).exactly(2).times # only the used(:judge) above
  end

  it "refuses as budget_exhausted once the calls are used, sends nothing, and Ollama answers" do
    AppSettings.llm_budget_judge_calls = 2
    2.times { expect(route).to include(text: "bridge answer") }

    lines = llm_usage_lines { expect(route).to include(text: "local answer", provider: "ollama") }
    expect(stub.requests.size).to eq(2)
    expect(lines.first).to include("provider" => "agent_cli", "refused" => "budget_exhausted", "prompt_chars" => 0, "outcome" => "error")
    expect(route("claude")).to include(ok: false, error: "budget_exhausted")
  end

  it "refuses once the estimated tokens are used" do
    AppSettings.llm_budget_judge_tokens = 10
    route

    expect(described_class.used(:judge)[:tokens]).to be >= 10
    expect(route).to include(provider: "ollama")
    expect(stub.requests.size).to eq(1)
  end

  it "counts backup models and the JSON retry as calls" do
    allow(handler).to receive(:call) do |request|
      request.json["model"] == "zq7-claude" ? [ 200, { ok: false, failure_class: "cli_quota" } ] : [ 200, { ok: true, text: "[1]" } ]
    end
    route("claude", task: :scan, options: { format: "json" })

    expect(stub.requests.map { |request| request.json["model"] }).to eq(%w[zq7-claude zq7-claude-b1 zq7-claude-b1])
    expect(described_class.used(:scan)[:calls]).to eq(3)
  end

  it "charges nothing when no model answered: not configured, bridge stopped, gate refusal, busy" do
    AppSettings.llm_budget_judge_calls = 1
    AppSettings.llm_profile_devin_model = ""
    route("devin,ollama")
    [ [ 503, { ok: false, failure_class: "gate_stale" } ], [ 429, {} ] ].each do |answer|
      allow(handler).to receive(:call).and_return(answer)
      route
    end
    stub.stop
    route

    expect(described_class.used(:judge)).to eq(calls: 0, tokens: 0)
    expect(described_class.exhausted?(:judge)).to be(false)
  end

  it "skips the JSON retry when the budget runs out after the first answer" do
    AppSettings.llm_budget_scan_calls = 1
    allow(handler).to receive(:call).and_return([ 200, { ok: true, text: "not json" } ])

    expect(route("claude,ollama", task: :scan, options: { format: "json" })).to include(provider: "ollama")
    expect(stub.requests.size).to eq(1)
  end

  it "keeps each task's budget apart, and starts every calendar day at zero" do
    AppSettings.llm_budget_judge_calls = 1
    travel_to(Time.zone.local(2026, 11, 4, 23, 50)) do
      route
      expect(route).to include(provider: "ollama")
      expect(described_class.exhausted?(:summary)).to be(false)
    end
    travel_to(Time.zone.local(2026, 11, 5, 0, 10)) do
      expect(described_class.used(:judge)).to eq(calls: 0, tokens: 0)
      expect(route).to include(text: "bridge answer")
    end
  end

  it "refuses when a set budget can't be read, and never fails the call when counting fails" do
    AppSettings.llm_budget_judge_calls = 5
    allow(cache).to receive(:read).and_raise(IOError)
    expect(described_class.exhausted?(:judge)).to be(true)

    allow(cache).to receive(:increment).and_raise(IOError)
    expect { described_class.charge(:judge, tokens: 3) }.not_to raise_error
  end
end
