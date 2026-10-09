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

    it "caps the temporal candidate list at MAX_TEMPORAL_CANDIDATES (fetching one extra to detect overflow)" do
      expect_any_instance_of(TemporalSearchStrategy)
        .to receive(:search).with(anything, limit: 501, entity_ids: nil).and_call_original

      described_class.call(query: "in 2026-08")
    end

    it "flags candidates_truncated when the cap bites and keeps totals honest" do
      stub_const("SubgraphSearchService::MAX_TEMPORAL_CANDIDATES", 3)
      5.times do |i|
        e = MemoryEntity.create!(name: "Extra #{i}", entity_type: "Project")
        MemoryObservation.create!(memory_entity: e, content: "f", created_at: Time.zone.parse("2026-08-10"))
      end

      result = described_class.call(query: "in 2026-08")

      expect(result[:pagination][:total_entities]).to eq(3)
      expect(result[:retrieval][:temporal][:candidates_truncated]).to be(true)
    end
  end

  describe "date-only fallback (residual terms match nothing)" do
    let!(:hot_entity) { MemoryEntity.create!(name: "Hot Service", entity_type: "Service") }

    before do
      MemoryObservation.create!(memory_entity: hot_entity, content: "august fact",
                                created_at: Time.zone.parse("2026-08-10"))
    end

    it "falls back to temporal listing when residual terms match nothing" do
      result = described_class.call(query: "zzz-nothing-matches in august 2026")

      expect(result[:entities].map { |e| e[:entity_id] }).to include(hot_entity.id)
      expect(result[:retrieval][:temporal][:fallback]).to eq("temporal_only")
    end

    it "matches residual terms instead of injecting unrelated in-window entities" do
      alpha = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
      beta = MemoryEntity.create!(name: "Beta Unrelated", entity_type: "Service")
      alpha.memory_observations.create!(content: "alpha fact", valid_from: Time.utc(2026, 8, 10))
      beta.memory_observations.create!(content: "beta fact", valid_from: Time.utc(2026, 8, 11))
      # Vector neighbours would mask the fallback decision — keep this spec on
      # the text channel only.
      allow_any_instance_of(VectorSearchStrategy).to receive(:search).and_return([])

      result = described_class.call(query: "alpha changes in august 2026")

      names = result[:entities].map { |e| e[:name] }
      expect(names).to include("Alpha Service")
      expect(names).not_to include("Beta Unrelated")
      expect(result[:retrieval][:temporal][:fallback]).to be_nil
    end
  end

  describe "text+window ordering" do
    let!(:hub) { MemoryEntity.create!(name: "Delta Service Hub", entity_type: "Service") }
    let!(:hot) { MemoryEntity.create!(name: "Echo Service", entity_type: "Service") }

    before do
      hub.memory_observations.create!(content: "old hub fact", valid_from: Time.utc(2024, 1, 1),
                                      valid_until: Time.utc(2024, 2, 1))
      hot.memory_observations.create!(content: "echo august fact", valid_from: Time.utc(2026, 8, 12))
      6.times do |i|
        leaf = MemoryEntity.create!(name: "Leaf #{i}", entity_type: "Note")
        MemoryRelation.create!(from_entity_id: hub.id, to_entity_id: leaf.id, relation_type: "has")
      end
    end

    it "ranks in-window candidates above out-of-window ones" do
      result = described_class.call(query: "service in august 2026")

      names = result[:entities].map { |e| e[:name] }
      expect(names.index("Echo Service")).to be < names.index("Delta Service Hub")
    end

    it "keeps today's booster order when no window applies" do
      result = described_class.call(query: "service")

      expect(result[:entities].map { |e| e[:name] }).to include("Delta Service Hub", "Echo Service")
    end
  end

  describe "max_tokens response envelope" do
    it "keeps the whole response under max_tokens whenever items are kept" do
      3.times do |i|
        e = MemoryEntity.create!(name: "Budget Seed #{i}", entity_type: "Service")
        e.memory_observations.create!(content: "budget fact")
      end

      result = described_class.call(query: "budget seed", include_observations: true,
                                    max_tokens: 400, per_page: 10)

      expect(result[:entities]).not_to be_empty
      expect(TokenBudget.estimate(result)).to be <= 400
    end
  end
end
