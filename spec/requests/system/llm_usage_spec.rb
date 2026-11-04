# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step U: the usage card in Settings › Summaries: per-day counts per task and
# provider, and each task's budget left. Numbers only: no prompt text, name or path.
RSpec.describe "System › Settings › LLM usage", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let!(:project) { MemoryEntity.create!(name: "Zq7Canary Project", entity_type: "Project", cloud_allowed: true) }
  let!(:widget) { MemoryEntity.create!(name: "Zq7CanaryWidget", entity_type: "Component", project_id: project.id) }
  let(:local) { FakeProvider.new(name: "ollama", result: { ok: true, text: "Zq7CanaryWidget answer", error: nil, latency_ms: 1.0 }) }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    AppSettings.clear_cache
    AppSettings.llm_profile_claude_model = "zq7-claude"
    allow(SummaryGenerationClient).to receive(:reset_instance!)
  end

  after { AppSettings.clear_cache }

  def card = Nokogiri::HTML(response.body).at_css("[data-testid='settings-llm-usage']")

  def call_judge
    prompt = Llm::Prompt.new.trusted("Judge:\n").data("Zq7CanaryWidget at /srv/zq7canary/app.rb").scoped(Llm::Scope.for_entities([ widget ]))
    with_llm_provider(local) { Llm::Router.generate(:judge, prompt, style: "concise") }
  end

  context "as the operator" do
    before { sign_in_operator }

    it "says there were no calls, and no budget set, by default" do
      get system_settings_path(tab: "summaries")

      expect(card.text).to include("LLM usage", "No LLM calls.", "summary: no budget set.", "judge: no budget set.")
    end

    it "counts calls, fallbacks and refusals per task and provider, today and the day before, with the budget left" do
      start_bridge_stub { [ 200, { ok: false, failure_class: "cli_quota" } ] }
      AppSettings.llm_chain_judge = "claude,ollama"
      AppSettings.llm_budget_judge_calls = 3
      travel_to(Time.zone.local(2026, 11, 3, 12)) { call_judge }
      travel_to(Time.zone.local(2026, 11, 4, 12)) do
        2.times { call_judge }
        AppSettings.llm_budget_judge_calls = 2
        call_judge
        get system_settings_path(tab: "summaries")
      end

      cells = ->(testid) { card.at_css("[data-testid='#{testid}']").css("td").map(&:text) }
      # Calls, ok, errors, fallbacks, refused; then the estimated tokens.
      expect(cells.call("llm-usage-2026-11-04-judge-agent_cli").first(7)).to eq(%w[judge agent_cli 2 0 2 0 1])
      expect(cells.call("llm-usage-2026-11-04-judge-ollama").first(7)).to eq(%w[judge ollama 3 3 0 3 0])
      expect(cells.call("llm-usage-2026-11-04-judge-ollama").last.to_i).to be_positive
      expect(cells.call("llm-usage-2026-11-03-judge-agent_cli").drop(2).first).to eq("1")
      expect(card.at_css("[data-testid='llm-budget-judge']").text.squish).to eq("judge: calls 0 of 2 left, tokens - today.")
      expect(card.text).not_to include("Zq7Canary", "zq7canary", "/srv/", "Judge:")
    end
  end

  it "refuses a guest (403)" do
    enable_guest!
    sign_in_guest
    get system_settings_path(tab: "summaries")

    expect(response).to have_http_status(:forbidden)
  end
end
