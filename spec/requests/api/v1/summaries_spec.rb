# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API V1 Summaries", type: :request do
  let!(:entity) do
    MemoryEntity.create!(name: "GraphMem", entity_type: "Project")
  end

  let!(:observation) do
    MemoryObservation.create!(
      memory_entity: entity,
      content: "GraphMem stores knowledge as entities, observations, and relations."
    )
  end

  before do
    AppSettings.clear_cache
    AppSettings.enable_llm_summarization = false
  end

  after { AppSettings.clear_cache }

  describe "POST /api/v1/summarize" do
    it "returns deterministic evidence for a valid query" do
      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )

      post "/api/v1/summarize", params: { query: "GraphMem" }, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["generation_mode"]).to eq("deterministic")
      expect(body["sources"]).to include(
        "entity_id" => entity.id,
        "observation_id" => observation.id
      )
    end

    it "returns an error when query is missing" do
      post "/api/v1/summarize", params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("query is required")
    end

    it "returns LLM output when enabled and provider succeeds" do
      AppSettings.enable_llm_summarization = true
      AppSettings.summary_url = "http://summary.test:11434"
      AppSettings.summary_model = "qwen3:8b"
      AppSettings.summary_provider = "ollama"

      allow(HybridSearchStrategy).to receive(:new).and_return(
        instance_double(HybridSearchStrategy, search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ])
      )
      allow(SummaryGenerationClient).to receive(:generate).and_return(
        { ok: true, text: "GraphMem is a knowledge graph.", error: nil }
      )

      post "/api/v1/summarize", params: { query: "GraphMem" }, as: :json

      body = JSON.parse(response.body)
      expect(body["generation_mode"]).to eq("llm")
      expect(body["summary"]).to eq("GraphMem is a knowledge graph.")
      expect(body["sources"]).not_to be_empty
    end
  end
end
