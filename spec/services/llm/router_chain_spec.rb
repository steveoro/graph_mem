# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step K: per-task chains (AppSettings llm_chain_<task>), the fallback rule and the
# inline skip, with agent_cli over the stub bridge and a FakeProvider in place of Ollama. The P0
# goldens (spec/services/llm/characterization_spec.rb) run on the default chain unchanged.
RSpec.describe "Llm::Router chains" do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }
  let(:local) { FakeProvider.new(name: "ollama", result: { ok: true, text: "local answer", error: nil, latency_ms: 1.0 }) }
  let(:bridge) { ->(_request) { [ 200, { ok: true, text: "bridge answer", failure_class: nil } ] } }
  let!(:stub) { start_bridge_stub { |request| bridge.call(request) } }

  before do
    AppSettings.clear_cache
    AppSettings.llm_agent_cli_profile = "claude"
    AppSettings.llm_agent_cli_model = "zq7-model"
  end

  after { AppSettings.clear_cache }

  def prompt = Llm::Prompt.new.trusted("Summarize:\n").data("SynthWidget renders frames.").scoped(Llm::Scope.for_entities([ widget ]))

  def chain!(task, value) = AppSettings.public_send(:"llm_chain_#{task}=", value)

  def route(task = :summary, inline: false) = with_llm_provider(local) { Llm::Router.generate(task, prompt, style: "concise", inline: inline) }

  def answering(status, body) = allow(bridge).to receive(:call).and_return([ status, body ])

  it "defaults every task to [:ollama], reads the setting on each call, and falls back to it for an unknown value" do
    expect(Llm::Router::TASKS.map { |task| Llm::Router.chain(task) }).to all(eq([ :ollama ]))
    expect(AppSettings.llm_chain_summary).to eq("ollama")

    chain!(:scan, "agent_cli,ollama")
    expect(Llm::Router.chain(:scan)).to eq(%i[agent_cli ollama])
    expect(Llm::Router.chain(:judge)).to eq([ :ollama ])
    chain!(:scan, "zq7,anything")
    expect(Llm::Router.chain(:scan)).to eq([ :ollama ])
    expect { Llm::Router.chain(:zq7) }.to raise_error(ArgumentError)
  end

  it "sends nothing to the bridge on the default chain" do
    expect(route).to include(ok: true, text: "local answer", provider: "ollama")
    expect(stub.requests).to be_empty
  end

  it "answers from agent_cli first when it succeeds" do
    chain!(:summary, "agent_cli,ollama")

    expect(route).to include(ok: true, text: "bridge answer", provider: "agent_cli")
    expect(local.calls).to be_empty
  end

  it "moves on to Ollama after an agent_cli failure: gate, tripped, busy, unauthorized, bad request, 500, unreachable, cli_*" do
    chain!(:summary, "agent_cli,ollama")
    rows = [ [ 503, { failure_class: "gate_stale" } ], [ 503, { failure_class: "tripped" } ], [ 429, {} ], [ 401, "" ], [ 400, {} ],
             [ 500, {} ], [ 200, { ok: false, failure_class: "cli_quota" } ], [ 200, { ok: false, failure_class: "cli_truncated" } ] ]
    rows.each do |status, body|
      answering(status, body)
      expect(route).to include(ok: true, text: "local answer", provider: "ollama"), status.to_s
    end
    stub.stop
    expect(route).to include(text: "local answer")
    expect(local.calls.size).to eq(rows.size + 1)
  end

  it "moves on after a CloudCall refusal, without calling the bridge" do
    chain!(:summary, "agent_cli,ollama")
    project.update!(cloud_allowed: false)

    expect(route).to include(text: "local answer")
    expect(stub.requests).to be_empty
  end

  it "returns a too-long prompt (413) and tool use instead of falling through, and logs both" do
    chain!(:scan, "agent_cli,ollama")
    answering(413, { failure_class: "prompt_too_long" })
    expect(route(:scan)).to include(ok: false, error: "prompt_too_long", http_status: 413, provider: "agent_cli")

    answering(200, { ok: false, failure_class: "cli_tool_use" })
    lines = llm_usage_lines { expect(route(:scan)).to include(ok: false, error: "agent_cli_tool_use", provider: "agent_cli") }
    expect(lines.sole).to include("provider" => "agent_cli", "outcome" => "error", "anonymized" => true)
    expect(local.calls).to be_empty
  end

  it "tries Ollama first in an ollama,agent_cli chain, and agent_cli only when Ollama doesn't answer at all" do
    chain!(:summary, "ollama,agent_cli")
    expect(route).to include(provider: "ollama")
    expect(stub.requests).to be_empty

    down = FakeProvider.new(name: "ollama", result: { ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0, http_status: nil })
    expect(with_llm_provider(down) { Llm::Router.generate(:summary, prompt, style: "concise") }).to include(ok: true, text: "bridge answer", provider: "agent_cli")
    expect(stub.requests.size).to eq(1)

    refused = FakeProvider.new(name: "ollama", result: { ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0, http_status: 413 })
    expect(with_llm_provider(refused) { Llm::Router.generate(:scan, prompt, style: "concise") }).to include(http_status: 413, provider: "ollama")
    bad = FakeProvider.new(name: "ollama", result: { ok: false, text: nil, error: "empty response", latency_ms: 1.0 })
    expect(with_llm_provider(bad) { Llm::Router.generate(:summary, prompt, style: "concise") }).to include(error: "empty response", provider: "ollama")
    expect(stub.requests.size).to eq(1)
  end

  it "returns Ollama's outage unchanged on the default chain" do
    down = FakeProvider.new(name: "ollama", result: { ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0, http_status: nil })

    expect(with_llm_provider(down) { Llm::Router.generate(:summary, prompt, style: "concise") })
      .to eq(ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.0, http_status: nil, provider: "ollama")
    expect(stub.requests).to be_empty
  end

  it "skips agent_cli for an inline call, and says so when nothing else is in the chain" do
    chain!(:judge, "agent_cli,ollama")
    expect(route(:judge, inline: true)).to include(text: "local answer")
    expect(stub.requests).to be_empty

    chain!(:judge, "agent_cli")
    lines = llm_usage_lines { expect(route(:judge, inline: true)).to eq(ok: false, text: nil, error: "inline_skipped", latency_ms: 0.0, provider: "agent_cli") }
    expect(lines.sole).to include("task" => "judge", "provider" => "agent_cli", "inline" => true, "refused" => "inline_skipped", "prompt_chars" => 0)
    expect(stub.requests).to be_empty
    expect(route(:judge)).to include(text: "bridge answer")
  end

  it "is usable when any provider in the chain is available" do
    unavailable = FakeProvider.new(available: false)
    with_llm_provider(unavailable) do
      expect(Llm::Router.usable?(:summary)).to be(false)
      chain!(:summary, "ollama,agent_cli")
      expect(Llm::Router.usable?(:summary)).to be(true)
      AppSettings.llm_agent_cli_model = ""
      expect(Llm::Router.usable?(:summary)).to be(false)
    end
  end
end
