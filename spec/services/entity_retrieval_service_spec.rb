# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntityRetrievalService do
  let!(:entity) { MemoryEntity.create!(name: "Retrieval Entity", entity_type: "Project") }

  it "returns hybrid search results with retrieval diagnostics" do
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(
        HybridSearchStrategy,
        search: [
          HybridSearchStrategy::SearchResult.new(entity: entity, score: 0.9, matched_fields: [ "name" ])
        ]
      )
    )

    payload = described_class.search("Retrieval", context_entity_ids: [ entity.id ])

    expect(payload[:results].size).to eq(1)
    expect(payload[:retrieval]).to include(:result_count, :semantic)
  end

  it "reports context scope truncation diagnostics" do
    scope = ProjectSubtree::Result.new(entity_ids: [ entity.id ], truncated: true, max_entities: 1_000)
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [])
    )

    payload = described_class.search("Retrieval", context_scope: scope)

    expect(payload[:retrieval]).to include(
      scope_entity_count: 1,
      scope_truncated: true,
      scope_max_entities: 1_000
    )
  end
end
