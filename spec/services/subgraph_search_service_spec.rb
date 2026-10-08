# frozen_string_literal: true

require "rails_helper"

RSpec.describe SubgraphSearchService do
  let(:vector_strategy) { instance_double(VectorSearchStrategy, search: []) }

  before { allow(VectorSearchStrategy).to receive(:new).and_return(vector_strategy) }

  describe ".call" do
    it "returns matched entities, observations, and internal relations" do
      first = MemoryEntity.create!(name: "Shared Alpha", entity_type: "Project")
      second = MemoryEntity.create!(name: "Shared Beta", entity_type: "Task")
      observation = MemoryObservation.create!(memory_entity: first, content: "Shared fact")
      relation = MemoryRelation.create!(from_entity: second, to_entity: first, relation_type: "part_of")

      result = described_class.call(query: "Shared")

      expect(result[:entities].pluck(:entity_id)).to contain_exactly(first.id, second.id)
      first_payload = result[:entities].find { |entity| entity[:entity_id] == first.id }
      expect(first_payload[:observations].pluck(:observation_id)).to include(observation.id)
      expect(result[:relations].pluck(:relation_id)).to include(relation.id)
    end

    it "omits unrequested projections" do
      MemoryEntity.create!(name: "Projection target", entity_type: "Project")

      result = described_class.call(
        query: "Projection",
        include_observations: false,
        include_relations: false
      )

      expect(result).not_to have_key(:relations)
      expect(result[:entities].first).not_to have_key(:observations)
    end

    it "filters observations to an explicit temporal window" do
      entity = MemoryEntity.create!(name: "Temporal scope", entity_type: "Project")
      inside = MemoryObservation.create!(
        memory_entity: entity, content: "in range", created_at: Time.zone.parse("2026-08-10")
      )
      MemoryObservation.create!(
        memory_entity: entity, content: "out of range", created_at: Time.zone.parse("2026-03-01")
      )

      result = described_class.call(
        query: "Temporal",
        temporal_window: TemporalWindow.from_params(
          occurred_after: "2026-08-01", occurred_before: "2026-08-31"
        )
      )

      payload = result[:entities].find { |item| item[:entity_id] == entity.id }
      expect(payload[:observations].pluck(:observation_id)).to eq([ inside.id ])
      expect(result[:retrieval][:temporal]).to include(:occurred_after, :occurred_before)
    end

    it "derives the temporal window from the query text" do
      result = described_class.call(query: "deploys in 2026-08")

      expect(result[:retrieval][:temporal]).to include(
        occurred_after: Time.zone.parse("2026-08-01").iso8601,
        occurred_before: Time.zone.parse("2026-08-31").end_of_day.iso8601
      )
    end

    it "packs entities under max_tokens and reports diagnostics" do
      MemoryEntity.create!(name: "Packed alpha", entity_type: "Project")
      MemoryEntity.create!(name: "Packed beta", entity_type: "Project")

      result = described_class.call(query: "Packed", max_tokens: 1)

      expect(result[:entities]).to eq([])
      expect(result[:retrieval][:token_budget]).to include(truncated: true)
    end

    it "preserves field and paging validations" do
      expect {
        described_class.call(query: "")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /blank/)
      expect {
        described_class.call(
          query: "x",
          search_in_name: false,
          search_in_type: false,
          search_in_aliases: false,
          search_in_observations: false
        )
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one/)
      expect {
        described_class.call(query: "x", page: 0)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Page number/)
    end
  end

  describe "purely temporal queries" do
    let!(:busy) { MemoryEntity.create!(name: "Busy", entity_type: "Project") }
    let!(:quiet) { MemoryEntity.create!(name: "Quiet", entity_type: "Project") }

    before do
      3.times do |i|
        MemoryObservation.create!(
          memory_entity: busy, content: "fact #{i}",
          created_at: Time.zone.parse("2026-08-10")
        )
      end
      MemoryObservation.create!(
        memory_entity: quiet, content: "fact",
        created_at: Time.zone.parse("2026-08-10")
      )
    end

    it "orders by in-window observation count without relevance re-ranking" do
      expect(SearchRelevanceBooster).not_to receive(:rank_entity_ids)

      result = described_class.call(query: "in 2026-08")

      ids = result[:entities].map { |e| e[:entity_id] }
      expect(ids.first).to eq(busy.id)
      expect(ids).to include(quiet.id)
    end

    it "does not cap the temporal candidate list" do
      expect_any_instance_of(TemporalSearchStrategy)
        .to receive(:search).with(anything, limit: nil, entity_ids: nil).and_call_original

      described_class.call(query: "in 2026-08")
    end
  end
end
