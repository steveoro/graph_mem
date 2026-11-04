# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step I: no request (MCP summarize, POST /api/v1/summaries, detect_contradictions)
# waits on the bridge unless the operator opted the summary task in; then one attempt, primary model
# only, with a capped timeout. generated_by names the answering model.
RSpec.describe "The inline gate" do
  let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id) }
  let(:handler) { ->(_request) { [ 200, { ok: true, text: "SynthWidget renders frames (observation_id=1).", failure_class: nil } ] } }
  let!(:stub) { start_bridge_stub { |request| handler.call(request) } }
  let(:local) { FakeProvider.new(name: "ollama", available: false) }

  before do
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    AppSettings.llm_profile_claude_backup_models = "zq7-claude-b1"
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders frames.")
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
    )
  end

  after { AppSettings.clear_cache }

  def summarize = with_llm_provider(local) { SummarizerService.call(query: "SynthWidget") }

  it "never reaches the bridge for a summary without the opt-in: inline_skipped, the deterministic summary" do
    AppSettings.llm_chain_summary = "claude"

    lines = llm_usage_lines { @response = summarize }

    expect(@response).to include(generation_mode: "deterministic", fallback_reason: "inline_skipped")
    expect(lines.sole).to include("task" => "summary", "provider" => "agent_cli", "inline" => false, "refused" => "inline_skipped")
    expect(stub.requests).to be_empty
  end

  it "keeps the MCP and REST summarize paths off the bridge too" do
    AppSettings.llm_chain_summary = "claude"
    with_llm_provider(local) { SummarizeTool.new.call(query: "SynthWidget") }

    expect(stub.requests).to be_empty
  end

  it "with the opt-in, makes one attempt with the capped timeout and no backup model, and names the model" do
    AppSettings.llm_chain_summary = "claude"
    AppSettings.llm_inline_cloud_tasks = "summary"
    AppSettings.llm_inline_cloud_timeout = 7

    expect(summarize).to include(generation_mode: "llm", generated_by: "zq7-claude")
    expect(stub.requests.sole.json).to include("model" => "zq7-claude", "timeout_s" => 7, "task" => "summary")

    allow(handler).to receive(:call).and_return([ 200, { ok: false, failure_class: "cli_quota" } ])
    stub.requests.clear
    expect(summarize).to include(generation_mode: "deterministic", fallback_reason: "agent_cli_quota")
    expect(stub.requests.map { |request| request.json["model"] }).to eq([ "zq7-claude" ])
  end

  it "with the opt-in, tries one cloud attempt only, then Ollama" do
    AppSettings.llm_chain_summary = "claude,devin,ollama"
    AppSettings.llm_profile_devin_model = "zq7-devin"
    AppSettings.llm_inline_cloud_tasks = "summary"
    allow(handler).to receive(:call).and_return([ 503, { ok: false, failure_class: "gate_stale" } ])
    answering = FakeProvider.new(name: "ollama", result: { ok: true, text: "SynthWidget renders frames.", error: nil, latency_ms: 1.0 })

    response = with_llm_provider(answering) { SummarizerService.call(query: "SynthWidget") }

    expect(response).to include(generation_mode: "llm", generated_by: SummarizationConfig.resolved_config[:model])
    expect(stub.requests.size).to eq(1)
  end

  it "caps the opt-in timeout between 5 and 60 seconds" do
    AppSettings.llm_chain_summary = "claude"
    AppSettings.llm_inline_cloud_tasks = "summary"
    AppSettings.where(var: "llm_inline_cloud_timeout").delete_all
    summarize
    expect(stub.requests.last.json["timeout_s"]).to eq(20)
  end

  it "never sends detect_contradictions to the bridge, opt-in or not" do
    AppSettings.llm_chain_judge = "claude"
    AppSettings.llm_inline_cloud_tasks = "summary"
    fact = fs_fact!(project, "Gadget Project uses the mcp gem.", tags: [ "replaces:fast-mcp" ])
    fs_observe!(widget, "SynthWidget runs on fast-mcp.")

    with_llm_provider(local) { DetectContradictionsTool.new.call(entity_id: project.id, mode: "outdated_by_fact", fact_observation_id: fact.id) }

    expect(stub.requests).to be_empty
  end
end
