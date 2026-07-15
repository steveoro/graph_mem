# frozen_string_literal: true

require "rails_helper"

RSpec.describe ObservationTrustRanker do
  let(:entity) { MemoryEntity.create!(name: "RankingEntity", entity_type: "Project") }

  describe ".rank" do
    it "returns 0 for a non-observation" do
      expect(described_class.rank(nil)).to eq(0.0)
      expect(described_class.rank("not an observation")).to eq(0.0)
    end

    it "caps the score between 0 and 1" do
      obs = MemoryObservation.create!(
        memory_entity: entity,
        content: "trusted",
        confidence: 1.0,
        source: "official"
      )

      expect(obs.trust_score).to be <= 1.0
      expect(obs.trust_score).to be >= 0.0
    end

    it "gives higher score to higher confidence observations" do
      low = MemoryObservation.create!(memory_entity: entity, content: "low", confidence: 0.2)
      high = MemoryObservation.create!(memory_entity: entity, content: "high", confidence: 0.9)

      expect(high.trust_score).to be > low.trust_score
    end

    it "gives higher score to trusted sources" do
      normal = MemoryObservation.create!(memory_entity: entity, content: "normal", confidence: 0.8, source: "some_blog")
      trusted = MemoryObservation.create!(memory_entity: entity, content: "trusted", confidence: 0.8, source: "official docs")

      expect(trusted.trust_score).to be > normal.trust_score
    end

    it "gives lower score to low-trust sources" do
      normal = MemoryObservation.create!(memory_entity: entity, content: "normal", confidence: 0.8, source: "docs")
      untrusted = MemoryObservation.create!(memory_entity: entity, content: "untrusted", confidence: 0.8, source: "hearsay")

      expect(untrusted.trust_score).to be < normal.trust_score
    end

    it "returns 0 for obsolete observations" do
      obs = MemoryObservation.create!(memory_entity: entity, content: "gone", confidence: 0.9)
      obs.mark_obsolete!(reason: "Outdated")

      expect(obs.trust_score).to eq(0.0)
    end

    it "returns 0 for observations whose validity window has expired" do
      obs = MemoryObservation.create!(
        memory_entity: entity,
        content: "expired",
        confidence: 0.9,
        valid_from: 2.days.ago,
        valid_until: 1.day.ago
      )

      expect(obs.trust_score).to eq(0.0)
    end

    it "penalizes observations whose validity window is in the future" do
      future = MemoryObservation.create!(
        memory_entity: entity,
        content: "future",
        confidence: 0.9,
        valid_from: 1.day.from_now
      )
      current = MemoryObservation.create!(memory_entity: entity, content: "current", confidence: 0.9)

      expect(future.trust_score).to be < current.trust_score
    end

    it "adds a structural boost for well-connected entities" do
      connected = MemoryObservation.create!(memory_entity: entity, content: "connected", confidence: 0.8)
      MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: MemoryEntity.create!(name: "Other", entity_type: "Task").id, relation_type: "relates_to")

      isolated = MemoryObservation.create!(memory_entity: MemoryEntity.create!(name: "Isolated", entity_type: "Project"), content: "isolated", confidence: 0.8)

      expect(connected.reload.trust_score).to be > isolated.trust_score
    end
  end
end
