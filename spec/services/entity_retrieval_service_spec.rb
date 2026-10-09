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

  describe "time-only fallback" do
    let!(:august_entity) { MemoryEntity.create!(name: "August Thing", entity_type: "Service") }

    before do
      august_entity.memory_observations.create!(content: "august fact",
                                                valid_from: Time.utc(2026, 8, 10))
    end

    it "falls back to the temporal channel when residual terms match nothing" do
      payload = described_class.search(
        "zzz-no-match in august 2026", semantic: false,
        temporal_window: TemporalWindow.new(occurred_after: "2026-08-01", occurred_before: "2026-08-31")
      )

      expect(payload[:results].map { |r| r.entity.id }).to include(august_entity.id)
      expect(payload[:retrieval][:temporal][:fallback]).to eq("temporal_only")
    end

    context "with an active project context" do
      let!(:context_project) { MemoryEntity.create!(name: "Context Project", entity_type: "Project") }
      let!(:other_project_entity) { MemoryEntity.create!(name: "Borealis Widget", entity_type: "Component") }

      before do
        other_project_entity.memory_observations.create!(content: "borealis fact",
                                                         valid_from: Time.utc(2026, 8, 12))
      end

      it "keeps context as a boost in the fallback — other projects' facts still match" do
        payload = described_class.search(
          "zzz-no-match in august 2026", semantic: false,
          context_entity_ids: [ context_project.id ],
          temporal_window: TemporalWindow.new(occurred_after: "2026-08-01", occurred_before: "2026-08-31")
        )

        ids = payload[:results].map { |r| r.entity.id }
        expect(ids).to include(august_entity.id, other_project_entity.id)
      end

      it "keeps context as a boost for purely temporal queries" do
        payload = described_class.search(
          "in august 2026", semantic: false,
          context_entity_ids: [ context_project.id ],
          temporal_window: TemporalWindow.new(occurred_after: "2026-08-01", occurred_before: "2026-08-31")
        )

        ids = payload[:results].map { |r| r.entity.id }
        expect(ids).to include(august_entity.id, other_project_entity.id)
      end

      it "honours an explicitly requested scope as a hard filter" do
        payload = described_class.search(
          "in august 2026", semantic: false,
          scope_entity_ids: [ context_project.id, august_entity.id ],
          temporal_window: TemporalWindow.new(occurred_after: "2026-08-01", occurred_before: "2026-08-31")
        )

        ids = payload[:results].map { |r| r.entity.id }
        expect(ids).to include(august_entity.id)
        expect(ids).not_to include(other_project_entity.id)
      end
    end
  end
end
