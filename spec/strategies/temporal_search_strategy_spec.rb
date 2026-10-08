# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalSearchStrategy do
  let(:strategy) { described_class.new }
  let(:window) do
    TemporalWindow.new(
      occurred_after: Time.zone.parse("2026-01-01"),
      occurred_before: Time.zone.parse("2026-01-31")
    )
  end

  let!(:entity_a) { MemoryEntity.create!(name: "Entity A", entity_type: "Project") }
  let!(:entity_b) { MemoryEntity.create!(name: "Entity B", entity_type: "Project") }
  let!(:entity_c) { MemoryEntity.create!(name: "Entity C", entity_type: "Project") }

  def add_observation(entity, content:, created_at: Time.zone.parse("2026-01-10"), status: MemoryObservation::ACTIVE_STATUS)
    attrs = { memory_entity: entity, content: content, created_at: created_at, status: status }
    attrs[:obsoleted_at] = created_at unless status == MemoryObservation::ACTIVE_STATUS
    MemoryObservation.create!(**attrs)
  end

  it "ranks entities by count of active observations inside the window" do
    3.times { |i| add_observation(entity_a, content: "a#{i}") }
    1.times { add_observation(entity_b, content: "b") }
    add_observation(entity_c, content: "outside", created_at: Time.zone.parse("2026-03-01"))

    ids = strategy.search(window)
    expect(ids.first).to eq(entity_a.id)
    expect(ids).to include(entity_b.id)
    expect(ids).not_to include(entity_c.id)
  end

  it "ignores obsolete and superseded observations" do
    add_observation(entity_a, content: "live")
    add_observation(entity_b, content: "dead", status: MemoryObservation::OBSOLETE_STATUS)

    ids = strategy.search(window)
    expect(ids).to eq([ entity_a.id ])
  end
  describe "entity_ids scoping" do
    let(:window) { TemporalWindow.new(occurred_after: "2026-10-01", occurred_before: "2026-10-31") }
    let!(:in_scope) { MemoryEntity.create!(name: "In Scope", entity_type: "Project") }
    let!(:out_of_scope) { MemoryEntity.create!(name: "Out Scope", entity_type: "Project") }

    before do
      MemoryObservation.create!(memory_entity: in_scope, content: "x", valid_from: "2026-10-10")
      MemoryObservation.create!(memory_entity: out_of_scope, content: "x", valid_from: "2026-10-10")
    end

    it "counts only scoped entities inside SQL, not after limiting" do
      ids = described_class.new.search(window, entity_ids: [ in_scope.id ])
      expect(ids).to eq([ in_scope.id ])
    end

    it "orders deterministically by count then id" do
      ids = described_class.new.search(window)
      expect(ids).to eq(ids.sort_by { |id| [ -MemoryObservation.where(memory_entity_id: id).count, id ] })
    end
  end
end
