# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step C2: Llm::AgentCliProvider over the stub bridge, and through Llm::CloudCall.
# Synthetic names (Zq7…), a random token, never a real bridge or model.
RSpec.describe Llm::AgentCliProvider do
  subject(:provider) { described_class.new }

  let!(:project) { MemoryEntity.create!(name: "Zq7Canary Project", entity_type: "Project", aliases: "Zq7cp") }
  let!(:widget) { MemoryEntity.create!(name: "Zq7CanaryWidget", entity_type: "Component", project_id: project.id) }
  # Answers with the first token of the prompt it was sent, so the answer must be restored.
  let(:handler) do
    lambda do |request|
      token = request.json["prompt"][/⟦ENT_\h+⟧/]
      [ 200, { ok: true, text: "#{token} renders frames.", failure_class: nil } ]
    end
  end
  let!(:stub) { start_bridge_stub { |request| handler.call(request) } }

  before do
    AppSettings.clear_cache
    AppSettings.llm_agent_cli_profile = "claude"
    AppSettings.llm_agent_cli_model = "zq7-model"
    # PR5: summaries reach the bridge only with the request opt-in (these examples route summaries).
    AppSettings.llm_inline_cloud_tasks = "summary"
  end

  after { AppSettings.clear_cache }

  def prompt = Llm::Prompt.new.trusted("Summarize:\n").data("Zq7CanaryWidget renders frames for Zq7Canary Project.").scoped(Llm::Scope.for_entities([ widget ]))

  it "is a cloud provider named agent_cli, registered as :agent_cli" do
    expect(provider).to have_attributes(name: "agent_cli", cloud?: true, model: "zq7-model", profile: "claude")
    expect(Llm::Registry.fetch(:agent_cli)).to be_a(described_class)
  end

  it "is available only with the bridge configured and a known profile and a valid model, without calling the bridge" do
    expect(provider.available?).to be(true)
    AppSettings.llm_agent_cli_profile = "cursor"
    expect(provider.available?).to be(false)
    AppSettings.llm_agent_cli_profile = "devin"
    [ "", "zq7 model", "-zq7", "x" * 65 ].each do |model|
      AppSettings.llm_agent_cli_model = model
      expect(provider.available?).to be(false), model
    end
    AppSettings.llm_agent_cli_model = "zq7-model"
    ENV["LLM_BRIDGE_URL"] = "http://localhost:#{stub.port}"
    expect(provider.available?).to be(false)
    expect(stub.requests).to be_empty
  end

  it "sends the profile, model, task and the caller's timeout (the summary timeout by default)" do
    provider.for_task(:judge).generate("Zq7 text", style: "concise", options: { timeout: 45, format: "json" })
    provider.generate("Zq7 text", style: "concise")

    judge, summary = stub.requests.map(&:json)
    expect(judge).to include("profile" => "claude", "model" => "zq7-model", "task" => "judge", "timeout_s" => 45)
    expect(summary).to include("task" => "summary", "timeout_s" => SummarizationConfig.resolved_config[:timeout].to_i.clamp(1, 600))
  end

  it "normalizes a JSON answer (fence and prose dropped) and cuts a summary as the summary client does" do
    text = JSON.parse(Rails.root.join("spec/fixtures/llm_bridge/envelopes/claude.json").read).fetch("result")
    allow(handler).to receive(:call).and_return([ 200, { ok: true, text: text, failure_class: nil } ])

    scan = provider.for_task(:scan).generate("Zq7", style: "concise", options: { format: "json", max_output_length: nil })
    expect(JSON.parse(scan[:text])).to have_key("architecture")
    expect(provider.generate("Zq7", style: "concise", options: { max_output_length: 20 })[:text]).to eq(text.strip[0, 20])
  end

  it "never raises, and answers bridge_not_configured without a profile or model" do
    AppSettings.llm_agent_cli_model = ""
    expect(provider.generate("Zq7", style: "concise")).to include(ok: false, error: "bridge_not_configured")
    AppSettings.llm_agent_cli_model = "zq7-model"
    allow(Llm::BridgeClient).to receive(:new).and_raise(RuntimeError, "boom")
    expect { described_class.new }.to raise_error(RuntimeError)
    client = instance_double(Llm::BridgeClient)
    allow(client).to receive(:complete).and_raise(RuntimeError, "Zq7 detail")
    expect(described_class.new(client: client).generate("Zq7", style: "concise")).to eq(ok: false, text: nil, error: "bridge_error", latency_ms: 0.0)
  end

  it "goes through CloudCall: refused until the project allows cloud, then masked out and restored back" do
    refused = with_llm_provider(provider) { Llm::Router.generate(:summary, prompt, style: "concise") }
    expect(refused).to include(ok: false, error: "cloud_not_allowed")
    expect(stub.requests).to be_empty

    project.update!(cloud_allowed: true)
    lines = llm_usage_lines { @result = with_llm_provider(provider) { Llm::Router.generate(:summary, prompt, style: "concise") } }

    sent = stub.requests.sole.json
    expect(sent["prompt"]).to start_with(Llm::CloudCall::INSTRUCTION)
    expect(sent["prompt"].gsub(/⟦[^⟧]*⟧/, "")).not_to include("Zq7Canary", "Zq7cp")
    expect(sent["task"]).to eq("summary")
    expect(@result).to include(ok: true, text: "Zq7CanaryWidget renders frames.", provider: "agent_cli")
    expect(lines.sole).to include("task" => "summary", "provider" => "agent_cli", "model" => "zq7-model", "outcome" => "ok",
                                  "anonymized" => true, "round_trip" => "ok")
  end
end
