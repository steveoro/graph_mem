# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step M: both profiles in one chain, each with a primary and backup models, over the
# stub bridge. Which failure moves to the next model, which to the next profile, and what stays.
RSpec.describe "Llm chains with profiles and backup models" do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }
  let(:local) { FakeProvider.new(name: "ollama", result: { ok: true, text: "local answer", error: nil, latency_ms: 1.0 }) }
  # "profile/model" => the bridge's answer; anything else answers ok with "<profile>/<model>".
  let(:answers) { {} }
  let!(:stub) do
    start_bridge_stub do |request|
      key = "#{request.json['profile']}/#{request.json['model']}"
      answers.fetch(key) { [ 200, { ok: true, text: "answer from #{key}", failure_class: nil } ] }
    end
  end

  before do
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1,zq7-claude-b2"
    AppSettings.llm_profile_devin_model = "zq7-devin"
  end

  after { AppSettings.clear_cache }

  def prompt = Llm::Prompt.new.trusted("Summarize:\n").data("SynthWidget renders frames.").scoped(Llm::Scope.for_entities([ widget ]))

  def route(task = :scan, chain: "claude,devin,ollama")
    AppSettings.public_send(:"llm_chain_#{task}=", chain)
    with_llm_provider(local) { Llm::Router.generate(task, prompt, style: "concise") }
  end

  def sent = stub.requests.map { |request| "#{request.json['profile']}/#{request.json['model']}" }

  def cli(klass) = [ 200, { ok: false, failure_class: klass } ]

  describe Llm::Chain do
    it "parses every listed value and nothing else" do
      expect(Llm::Chain::VALUES).to include("ollama", "agent_cli", "agent_cli,ollama", "ollama,agent_cli", "claude", "devin,claude,ollama")
      expect(Llm::Chain::VALUES.size).to eq(12)
      expect(Llm::Chain.parse("devin,claude,ollama")).to eq(%i[devin claude ollama])
      [ "ollama,claude", "claude,claude", "cursor", "" ].each { |value| expect(Llm::Chain.parse(value)).to be_nil }
      AppSettings.llm_chain_judge = "ollama,claude"
      expect(Llm::Router.chain(:judge)).to eq([ :ollama ])
    end

    it "lists a profile's primary, then up to three valid backups, without repeats or the primary" do
      AppSettings.llm_profile_claude_backup_models = "zq7-claude, zq7-b1,zq7-b1, -bad, zq7-b2,zq7-b3,zq7-b4"

      expect(Llm::Chain.models(:claude)).to eq([ %w[claude zq7-claude], %w[claude zq7-b1], %w[claude zq7-b2], %w[claude zq7-b3] ])
      AppSettings.llm_profile_devin_model = ""
      expect(Llm::Chain.models(:devin)).to eq([ [ "devin", "" ] ])
    end

    it "keeps PR4's agent_cli value: its own profile and model, unless that profile's own model is set" do
      AppSettings.llm_agent_cli_profile = "devin"
      AppSettings.llm_agent_cli_model = "zq7-legacy"
      AppSettings.llm_profile_devin_model = ""
      expect(Llm::Chain.models(:agent_cli)).to eq([ %w[devin zq7-legacy] ])
      expect(route(chain: "agent_cli")).to include(ok: true, text: "answer from devin/zq7-legacy")

      AppSettings.llm_profile_devin_model = "zq7-devin"
      AppSettings.llm_profile_devin_backup_models = "zq7-devin-b1"
      expect(Llm::Chain.models(:agent_cli)).to eq([ %w[devin zq7-devin], %w[devin zq7-devin-b1] ])
    end
  end

  it "answers from the first profile's primary model, one request" do
    expect(route).to include(ok: true, text: "answer from claude/zq7-claude", provider: "agent_cli")
    expect(sent).to eq([ "claude/zq7-claude" ])
  end

  it "moves to the profile's next model on each model trigger, with one [llm] line per attempt" do
    { "cli_model_unavailable" => cli("cli_model_unavailable"), "cli_payment_required" => cli("cli_payment_required"),
      "cli_quota" => cli("cli_quota"), "cli_rate_limited" => cli("cli_rate_limited"),
      "gate_missing" => [ 503, { ok: false, failure_class: "gate_missing" } ] }.each do |trigger, answer|
      answers.replace("claude/zq7-claude" => answer)
      stub.requests.clear
      lines = llm_usage_lines { expect(route).to include(ok: true, text: "answer from claude/zq7-claude-b1"), trigger }
      expect(sent).to eq([ "claude/zq7-claude", "claude/zq7-claude-b1" ])
      expect(lines.map { |line| line.values_at("profile", "model", "fallback_step", "outcome") })
        .to eq([ [ "claude", "zq7-claude", 0, "error" ], [ "claude", "zq7-claude-b1", 1, "ok" ] ])
    end
  end

  it "walks every backup, then the next profile, then Ollama" do
    answers.merge!("claude/zq7-claude" => cli("cli_quota"), "claude/zq7-claude-b1" => cli("cli_quota"),
                   "claude/zq7-claude-b2" => cli("cli_model_unavailable"), "devin/zq7-devin" => cli("cli_rate_limited"))

    lines = llm_usage_lines { expect(route).to include(ok: true, text: "local answer", provider: "ollama") }
    expect(sent).to eq([ "claude/zq7-claude", "claude/zq7-claude-b1", "claude/zq7-claude-b2", "devin/zq7-devin" ])
    expect(lines.map { |line| line["fallback_step"] }).to eq([ 0, 1, 2, 3, 4 ])
    expect(lines.last).to include("provider" => "ollama")
    expect(lines.last).not_to have_key("profile")
  end

  it "skips the rest of a profile's models on a profile or bridge failure" do
    [ [ 503, { ok: false, failure_class: "gate_stale" } ], [ 503, { ok: false, failure_class: "tripped" } ], [ 429, {} ], [ 401, "" ],
      cli("cli_auth"), cli("cli_timeout"), cli("cli_truncated") ].each do |answer|
      answers.replace("claude/zq7-claude" => answer)
      stub.requests.clear
      expect(route).to include(ok: true, text: "answer from devin/zq7-devin"), answer.inspect
      expect(sent).to eq([ "claude/zq7-claude", "devin/zq7-devin" ])
    end
    stub.stop
    expect(route).to include(text: "local answer")
  end

  it "returns a too-long prompt and tool use without trying a backup, another profile or Ollama" do
    answers.replace("claude/zq7-claude" => [ 413, { ok: false, failure_class: "prompt_too_long" } ])
    expect(route).to include(ok: false, error: "prompt_too_long", http_status: 413)

    answers.replace("claude/zq7-claude" => cli("cli_tool_use"))
    expect(route).to include(ok: false, error: "agent_cli_tool_use")
    expect(sent).to eq([ "claude/zq7-claude", "claude/zq7-claude" ])
    expect(local.calls).to be_empty
  end

  it "moves past an unconfigured profile, and past refused profiles to Ollama, sending nothing" do
    AppSettings.llm_profile_claude_model = ""
    expect(route(chain: "claude,devin")).to include(text: "answer from devin/zq7-devin")

    project.update!(cloud_allowed: false)
    stub.requests.clear
    expect(route(chain: "claude,devin,ollama")).to include(text: "local answer")
    expect(route(chain: "claude,devin")).to include(ok: false, error: "cloud_not_allowed")
    expect(stub.requests).to be_empty
  end

  it "is usable when a profile's primary model is set, and tries nothing for the default chain" do
    AppSettings.llm_chain_scan = "claude"
    expect(Llm::Router.usable?(:scan)).to be(true)
    AppSettings.llm_profile_claude_model = ""
    expect(Llm::Router.usable?(:scan)).to be(false)

    AppSettings.llm_chain_scan = "ollama"
    lines = llm_usage_lines { with_llm_provider(local) { Llm::Router.generate(:scan, prompt, style: "concise") } }
    expect(lines.sole.keys).not_to include("fallback_step", "profile")
    expect(stub.requests).to be_empty
  end
end
