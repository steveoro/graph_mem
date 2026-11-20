# frozen_string_literal: true

require "rails_helper"

# 1.92.0: the policy-only `resolution: :supersede` keyword on the contradiction apply path. The
# default (:obsolete) is what the UI and MCP use, and is covered by the existing contradiction specs.
RSpec.describe CompactionReviewApplier::Contradiction, "resolution: :supersede" do
  let!(:entity) { MemoryEntity.create!(name: "SynthService", entity_type: "Service") }
  let!(:older) { MemoryObservation.create!(memory_entity: entity, content: "Port: 3000") }
  let!(:newer) { MemoryObservation.create!(memory_entity: entity, content: "Port: 3001") }

  def seed(first, second)
    item = { id: SecureRandom.uuid, kind: "contradiction", observation_id_1: first.id, observation_id_2: second.id,
             entity_id_1: first.memory_entity_id, entity_id_2: second.memory_entity_id, distance: 0.05, confidence: 0.99 }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan", items: [ item ]).sole
  end

  it "marks the other side superseded by the kept one, with the value change in the reason" do
    row = seed(older, newer)
    result = CompactionReviewService.apply(row.row_uuid, { keep_observation_id: newer.id }, resolution: :supersede)

    expect(result).to include(success: true, message: "Kept observation ##{newer.id}; ##{older.id} superseded by it")
    expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id,
                                            obsolescence_reason: "Superseded by observation ##{newer.id} (value change: 3000 → 3001)")
    expect(newer.reload).to have_attributes(status: "active", superseded_by_id: nil)
    expect(row.reload.status).to eq("approved")
  end

  it "keeps the default: without the keyword the other side is obsolete, with no link" do
    row = seed(older, newer)
    CompactionReviewService.apply(row.row_uuid, { keep_observation_id: newer.id, resolution: "supersede" })

    expect(older.reload).to have_attributes(status: "obsolete", superseded_by_id: nil)
  end

  it "refuses to supersede across two entities, and leaves the row open" do
    other = MemoryObservation.create!(memory_entity: MemoryEntity.create!(name: "SynthWorker", entity_type: "Service"), content: "Port: 3002")
    row = seed(older, other)
    result = CompactionReviewService.apply(row.row_uuid, { keep_observation_id: other.id }, resolution: :supersede)

    expect(result).to include(success: false)
    expect(result[:error]).to include("two entities")
    expect(older.reload.status).to eq("active")
    expect(row.reload.status).to eq("active")
  end
end
