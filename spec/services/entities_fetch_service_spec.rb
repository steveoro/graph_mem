# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntitiesFetchService do
  let!(:first) { MemoryEntity.create!(name: "First", entity_type: "Project") }
  let!(:second) { MemoryEntity.create!(name: "Second", entity_type: "Task") }
  let!(:outside) { MemoryEntity.create!(name: "Outside", entity_type: "Issue") }
  let!(:internal_relation) do
    MemoryRelation.create!(from_entity: first, to_entity: second, relation_type: "part_of")
  end
  let!(:outside_relation) do
    MemoryRelation.create!(from_entity: first, to_entity: outside, relation_type: "relates_to")
  end

  describe ".call" do
    it "preserves input order and defaults a single ID to all incident relations" do
      result = described_class.call(entity_ids: [ first.id ])

      expect(result[:entities].pluck(:entity_id)).to eq([ first.id ])
      expect(result[:relations].pluck(:relation_id)).to contain_exactly(
        internal_relation.id,
        outside_relation.id
      )
      expect(result[:relation_scope]).to eq("all")
    end

    it "defaults multiple IDs to internal relations" do
      result = described_class.call(entity_ids: [ second.id, first.id ])

      expect(result[:entities].pluck(:entity_id)).to eq([ second.id, first.id ])
      expect(result[:relations].pluck(:relation_id)).to eq([ internal_relation.id ])
      expect(result[:relation_scope]).to eq("internal")
    end

    it "supports all incident relations for multiple IDs without duplicates" do
      result = described_class.call(entity_ids: [ first.id, second.id ], relations: "all")

      expect(result[:relations].pluck(:relation_id)).to contain_exactly(
        internal_relation.id,
        outside_relation.id
      )
    end

    it "reports missing IDs for a multi-entity request" do
      result = described_class.call(entity_ids: [ first.id, 999_999 ])

      expect(result[:entities].pluck(:entity_id)).to eq([ first.id ])
      expect(result[:missing_entity_ids]).to eq([ 999_999 ])
    end

    it "raises for one missing ID and for an empty request" do
      expect {
        described_class.call(entity_ids: [ 999_999 ])
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect {
        described_class.call(entity_ids: [])
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /cannot be empty/)
    end

    it "ranks, limits, and optionally includes obsolete observations" do
      lower = MemoryObservation.create!(memory_entity: first, content: "Lower")
      higher = MemoryObservation.create!(memory_entity: first, content: "Higher")
      obsolete = MemoryObservation.create!(memory_entity: first, content: "Historical")
      lower.update_column(:trust_score, 0.1)
      higher.update_column(:trust_score, 0.9)
      obsolete.mark_obsolete!

      current = described_class.call(
        entity_ids: [ first.id ],
        include_ranked: true,
        observation_limit: 1
      )
      historical = described_class.call(entity_ids: [ first.id ], include_obsolete: true)

      expect(current.dig(:entities, 0, :observations).pluck(:observation_id)).to eq([ higher.id ])
      expect(current.dig(:entities, 0, :observations_truncated)).to be(true)
      expect(historical.dig(:entities, 0, :observations).pluck(:observation_id)).to include(obsolete.id)
    end
  end
end
