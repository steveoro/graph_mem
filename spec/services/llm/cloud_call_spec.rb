# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR2, step A2: the Router's cloud path, through a FakeProvider(cloud: true). No real
# provider exists; every value is synthetic.
RSpec.describe Llm::CloudCall do
  let!(:project) { MemoryEntity.create!(name: "Zq7Canary Project", entity_type: "Project", aliases: "Zq7cp") }
  let!(:widget) { MemoryEntity.create!(name: "Zq7CanaryWidget", entity_type: "Component", project_id: project.id) }
  let(:canaries) { [ "Zq7Canary", "zq7canary", "Zq7cp", "ops@zq7canary.example" ] }

  def prompt(data = "Zq7CanaryWidget mails ops@zq7canary.example about Zq7cp.")
    Llm::Prompt.new.trusted("Summarize:\n").data(data).scoped(Llm::Scope.for_entities([ widget ]))
  end

  # Echoes the prompt's first two tokens back, in a sentence.
  def echo = FakeProvider.new(cloud: true) { |text, **| { ok: true, text: "Done: #{text.scan(/⟦\w+⟧/).first(2).join(' and ')}.", error: nil, latency_ms: 3.0 } }

  def allow_cloud = project.update!(cloud_allowed: true)

  it "leaves a local provider exactly as in 1.67.0: a String, no gate, no scope, no anonymizer" do
    local = FakeProvider.new(result: { ok: true, text: "ok", error: nil, latency_ms: 1.0 })
    allow(Llm::Anonymizer::Session).to receive(:new)
    allow(Llm::CloudGate).to receive(:allowed?)
    scoped = prompt
    allow(scoped.scope).to receive(:project_ids)

    lines = llm_usage_lines { with_llm_provider(local) { expect(Llm::Router.generate(:summary, scoped, style: "concise")).to eq(ok: true, text: "ok", error: nil, latency_ms: 1.0, provider: "fake") } }

    expect(local.calls.sole.prompt).to be_a(String).and eq(scoped.to_s)
    expect(lines.sole.keys).to eq(%w[task provider model inline prompt_chars est_in_tokens out_chars est_out_tokens latency_ms outcome])
    expect(Llm::Anonymizer::Session).not_to have_received(:new)
    expect(Llm::CloudGate).not_to have_received(:allowed?)
    expect(scoped.scope).not_to have_received(:project_ids)
  end

  it "refuses without calling the provider: a String, a project that doesn't allow cloud, unscoped data, a token-like input" do
    fake = echo
    refusals = with_llm_provider(fake) do
      allowed_unscoped = Llm::Prompt.new.data("x").scoped(Llm::Scope.for_entities([ MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") ]))
      [ "plain text", prompt ].map { |input| Llm::Router.generate(:summary, input, style: "concise") } +
        [ allow_cloud && Llm::Router.generate(:summary, allowed_unscoped, style: "concise"),
          Llm::Router.generate(:summary, prompt("see ⟦ENT_ab12⟧"), style: "concise") ]
    end

    expect(refusals.map { |result| result[:error] }).to eq(%w[prompt_not_segmented cloud_not_allowed cloud_not_allowed anonymizer_refused])
    expect(refusals).to all(include(ok: false, text: nil, latency_ms: 0.0, provider: "fake"))
    expect(fake.calls).to be_empty
  end

  it "sends the masked text with the token instruction, and restores the answer" do
    allow_cloud
    fake = echo

    result = nil
    lines = llm_usage_lines { with_llm_provider(fake) { result = Llm::Router.generate(:summary, prompt, style: "concise") } }

    sent = fake.calls.sole.prompt
    expect(sent).to start_with(described_class::INSTRUCTION + "Summarize:\n⟦ENT_")
    expect(sent).not_to include(*canaries)
    expect(result).to include(ok: true, text: "Done: Zq7CanaryWidget and ops@zq7canary.example.", provider: "fake")
    expect(lines.sole).to include("anonymized" => true, "masked" => { "ENT" => 1, "EMAIL" => 1, "PRJ" => 1 }, "secrets" => 0,
                                  "round_trip" => "ok", "leftover_out" => 0, "prompt_chars" => sent.length)
    expect(lines.to_json).not_to include(*canaries, "⟦")
  end

  it "restores JSON answers JSON-escaped, so the caller's parser runs unchanged" do
    allow_cloud
    MemoryEntity.create!(name: 'Zq7 "Q" Widget', entity_type: "Component", project_id: project.id)
    fake = FakeProvider.new(cloud: true) { |text, **| { ok: true, text: { name: text[/⟦ENT_\h+⟧/] }.to_json, error: nil, latency_ms: 1.0 } }

    result = with_llm_provider(fake) { Llm::Router.generate(:judge, prompt('Zq7 "Q" Widget'), style: "concise", options: { format: "json" }) }

    expect(JSON.parse(result[:text])).to eq("name" => 'Zq7 "Q" Widget')
  end

  it "fails an invented token, and a scan answer that writes out a masked name" do
    allow_cloud
    invented = FakeProvider.new(cloud: true, result: { ok: true, text: "⟦ENT_beef⟧", error: nil, latency_ms: 1.0 })
    plain = FakeProvider.new(cloud: true, result: { ok: true, text: "Zq7CanaryWidget", error: nil, latency_ms: 1.0 })

    expect(with_llm_provider(invented) { Llm::Router.generate(:summary, prompt, style: "concise") })
      .to include(ok: false, text: nil, error: "anonymization_round_trip_failed", provider: "fake")
    lines = llm_usage_lines do
      expect(with_llm_provider(plain) { Llm::Router.generate(:scan, prompt, style: "concise") }).to include(error: "anonymization_round_trip_failed")
      expect(with_llm_provider(plain) { Llm::Router.generate(:summary, prompt, style: "concise") }).to include(ok: true)
    end
    expect(lines.map { |line| line.values_at("round_trip", "leftover_out") }).to eq([ [ "failed", 1 ], [ "ok", 1 ] ])
  end

  it "logs a refusal with its reason and nothing sent" do
    lines = llm_usage_lines { with_llm_provider(echo) { Llm::Router.generate(:judge, prompt("⟦x⟧"), style: "concise", inline: true) } }

    expect(lines.sole).to include("task" => "judge", "inline" => true, "outcome" => "error", "refused" => "cloud_not_allowed", "prompt_chars" => 0)
    allow_cloud
    lines = llm_usage_lines { with_llm_provider(echo) { Llm::Router.generate(:judge, prompt("⟦x⟧"), style: "concise") } }
    expect(lines.sole).to include("refused" => "anonymizer_refused", "refused_detail" => "collision")
  end

  it "moves on to the next provider after a refusal, and stops after a provider call" do
    stub_const("Llm::Router::CHAIN", %i[cloudy ollama])
    local = FakeProvider.new(name: "local", result: { ok: true, text: "local answer", error: nil, latency_ms: 1.0 })
    cloudy = echo
    route = lambda do
      with_llm_provider(local) do
        Llm::Registry.override(:cloudy, cloudy)
        Llm::Router.generate(:summary, prompt, style: "concise")
      end
    end

    expect(route.call).to include(text: "local answer", provider: "local")
    allow_cloud
    expect(route.call).to include(provider: "fake", ok: true)
    expect(local.calls.size).to eq(1)
    expect(cloudy.calls.size).to eq(1)
  end
end
