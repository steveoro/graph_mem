# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step M: the per-profile model and backup fields in Settings › Summaries.
RSpec.describe "System › Settings › LLM profiles", type: :request do
  before do
    AppSettings.clear_cache
    sign_in_operator
    allow(SummaryGenerationClient).to receive(:reset_instance!)
  end

  after { AppSettings.clear_cache }

  def save(settings) = patch(system_settings_path, params: { tab: "summaries", settings: settings })

  it "shows each profile's model and backup fields, and saves them normalized" do
    get system_settings_path(tab: "summaries")
    %w[claude devin].each do |profile|
      expect(response.body).to include("settings[llm_profile_#{profile}_model]", "settings[llm_profile_#{profile}_backup_models]")
    end

    save(llm_chain_scan: "claude,devin,ollama", llm_profile_claude_model: "zq7-claude", llm_profile_claude_backup_models: " zq7-b1 , zq7-b2 ")

    expect(response).to redirect_to(system_settings_path(tab: "summaries"))
    expect(AppSettings.llm_profile_claude_backup_models).to eq("zq7-b1,zq7-b2")
    expect(Llm::Router.chain(:scan)).to eq(%i[claude devin ollama])
  end

  it "refuses more than three backups, a repeat, a flag-like model, and a chain outside the list" do
    { llm_profile_devin_backup_models: "a1,a2,a3,a4", llm_profile_claude_backup_models: "a1,a1",
      llm_profile_devin_model: "--zq7", llm_chain_judge: "ollama,claude" }.each do |key, value|
      save(key => value)
      expect(response).to have_http_status(:unprocessable_content), key.to_s
    end
    expect(AppSettings.llm_chain_judge).to eq("ollama")
  end
end
