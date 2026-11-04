# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR4, step K: the chain, profile and model fields in Settings › Summaries.
RSpec.describe "System › Settings › LLM chains", type: :request do
  before { AppSettings.clear_cache }
  after { AppSettings.clear_cache }

  def save(settings) = patch(system_settings_path, params: { tab: "summaries", settings: settings })

  context "as the operator" do
    before do
      sign_in_operator
      allow(SummaryGenerationClient).to receive(:reset_instance!)
    end

    it "shows each chain as a fixed list, ollama selected by default, and the profile and model fields" do
      get system_settings_path(tab: "summaries")

      page = Nokogiri::HTML(response.body)
      %w[summary scan judge].each do |task|
        select = page.at_css("select[name='settings[llm_chain_#{task}]']")
        expect(select.css("option").map { |option| option["value"] }.compact_blank).to eq(Llm::Router::CHAIN_VALUES)
        expect(select.at_css("option[selected]")["value"]).to eq("ollama")
      end
      expect(page.at_css("select[name='settings[llm_agent_cli_profile]']").css("option").map(&:text)).to include("claude", "devin")
      expect(page.at_css("input[name='settings[llm_agent_cli_model]']")).to be_present
    end

    it "saves a chain, the profile and the model" do
      save(llm_chain_scan: "agent_cli,ollama", llm_agent_cli_profile: "devin", llm_agent_cli_model: " zq7-model ")

      expect(response).to redirect_to(system_settings_path(tab: "summaries"))
      expect([ AppSettings.llm_chain_scan, AppSettings.llm_agent_cli_profile, AppSettings.llm_agent_cli_model ]).to eq([ "agent_cli,ollama", "devin", "zq7-model" ])
      expect(Llm::Router.chain(:scan)).to eq(%i[agent_cli ollama])
      expect(AppSettings.llm_chain_summary).to eq("ollama")
    end

    it "stores the default for a blank chain and refuses free text, an unknown profile and a flag-like model" do
      save(llm_chain_judge: "")
      expect(AppSettings.llm_chain_judge).to eq("ollama")

      { llm_chain_summary: "openai", llm_agent_cli_profile: "cursor", llm_agent_cli_model: "--model" }.each do |key, value|
        save(key => value)
        expect(response).to have_http_status(:unprocessable_content), key.to_s
        expect(AppSettings.public_send(key)).not_to eq(value)
      end
    end
  end

  it "refuses a guest (403)" do
    enable_guest!
    sign_in_guest
    save(llm_chain_scan: "agent_cli")

    expect(response).to have_http_status(:forbidden)
    expect(AppSettings.llm_chain_scan).to eq("ollama")
  end
end
