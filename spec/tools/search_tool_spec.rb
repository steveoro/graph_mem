# frozen_string_literal: true

require "rails_helper"

RSpec.describe SearchTool, type: :model do
  let(:tool) { described_class.new }

  describe "#call" do
    it "returns a uniform summary envelope for a query without projections" do
      result_object = instance_double(HybridSearchStrategy::SearchResult, to_h: { entity_id: 7, name: "Result" })
      allow(EntityRetrievalService).to receive(:search).and_return(
        results: [ result_object ],
        retrieval: { scope_entity_count: nil, result_count: 1 }
      )

      result = tool.call(query: "result")

      expect(result).to include(
        mode: "summary",
        results: [ { entity_id: 7, name: "Result" } ],
        pagination: { per_page: 20, current_page: 1 }
      )
      expect(result[:retrieval][:result_count]).to eq(1)
    end

    it "pages summary results without changing the response shape" do
      result_objects = 4.times.map do |index|
        instance_double(
          HybridSearchStrategy::SearchResult,
          to_h: { entity_id: index + 1, name: "Result #{index + 1}" }
        )
      end
      allow(EntityRetrievalService).to receive(:search).and_return(
        results: result_objects,
        retrieval: { result_count: 4 }
      )

      result = tool.call(query: "result", page: 2, per_page: 2)

      expect(result[:results].pluck(:entity_id)).to eq([ 3, 4 ])
      expect(EntityRetrievalService).to have_received(:search).with("result", hash_including(limit: 4))
    end

    it "returns catalog mode when query is omitted" do
      MemoryEntity.create!(name: "Catalog entity", entity_type: "Project")

      result = tool.call

      expect(result[:mode]).to eq("catalog")
      expect(result[:entities].first).to include(name: "Catalog entity")
      expect(result[:pagination]).to include(per_page: 20, current_page: 1)
    end

    it "returns only requested subgraph projections" do
      allow(SubgraphSearchService).to receive(:call).and_return(
        entities: [ { entity_id: 1 } ],
        pagination: { total_entities: 1 },
        retrieval: {},
        relations: [ { relation_id: 2 } ]
      )

      result = tool.call(query: "graph", include: [ "relations" ])

      expect(result[:mode]).to eq("subgraph")
      expect(result[:relations]).to eq([ { relation_id: 2 } ])
      expect(SubgraphSearchService).to have_received(:call).with(
        hash_including(include_observations: false, include_relations: true)
      )
    end

    it "rejects blank queries, projections without a query, and unknown projections" do
      expect { tool.call(query: "") }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /blank/)
      expect {
        tool.call(include: [ "relations" ])
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /require a query/)
      expect {
        tool.call(query: "x", include: [ "unknown" ])
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /include values/)
    end

    it "validates canonical paging" do
      expect { tool.call(page: 0) }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Page number/)
      expect { tool.call(per_page: 101) }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Per page/)
    end

    it "passes explicit temporal bounds through as a TemporalWindow" do
      allow(EntityRetrievalService).to receive(:search).and_return(results: [], retrieval: {})

      tool.call(query: "deploys", occurred_after: "2026-08-01", occurred_before: "2026-08-31")

      expect(EntityRetrievalService).to have_received(:search).with(
        "deploys",
        hash_including(temporal_window: an_instance_of(TemporalWindow))
      )
    end

    it "rejects temporal bounds and max_tokens without a query" do
      expect {
        tool.call(occurred_after: "2026-08-01")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /require a query/)
      expect {
        tool.call(max_tokens: 100)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /require a query/)
    end

    it "rejects as_of combined with occurred bounds" do
      expect {
        tool.call(query: "deploys", as_of: "2026-08-15", occurred_after: "2026-08-01")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /cannot be combined/)
    end

    it "packs summary results under max_tokens with diagnostics" do
      big = { entity_id: 1, name: "x" * 400 }
      small = { entity_id: 2, name: "y" }
      result_objects = [ small, big ].map do |payload|
        instance_double(HybridSearchStrategy::SearchResult, to_h: payload)
      end
      allow(EntityRetrievalService).to receive(:search).and_return(
        results: result_objects,
        retrieval: { result_count: 2 }
      )

      budget = TokenBudget.estimate(small)
      result = tool.call(query: "result", max_tokens: budget)

      expect(result[:results]).to eq([ small ])
      expect(result[:retrieval][:token_budget]).to include(truncated: true)
    end
  end
end
