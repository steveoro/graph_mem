# frozen_string_literal: true

require "rails_helper"

# A contradiction apply is a review.apply set (strategy audit, 30 days): undo re-activates the
# retired observation and reopens the row through the existing AuditInverse + ReviewRows.
RSpec.describe "Undo of a contradiction apply" do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:kept) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget supports dark mode.") }
  let!(:other) { MemoryObservation.create!(memory_entity: beta, content: "SynthWidget does not support dark mode.") }
  let!(:row) do
    item = { id: SecureRandom.uuid, kind: "contradiction", observation_id_1: kept.id, observation_id_2: other.id,
             entity_id_1: widget.id, entity_id_2: beta.id, distance: 0.08, confidence: 0.95 }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan", items: [ item ]).sole
  end

  def undo(uuid)
    ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")
  end

  it "applies, undoes and redoes end to end" do
    applied = CompactionReviewService.apply(row.row_uuid, { keep_observation_id: kept.id })
    set = ChangeSet.find_by!(uuid: applied[:change_set_uuid])

    expect(set).to have_attributes(kind: "review.apply", undo_strategy: "audit")
    expect(set.undoable_until).to be_within(1.minute).of(30.days.from_now)
    expect(other.reload.status).to eq("obsolete")
    expect(row.reload).to have_attributes(status: "approved", change_set_id: set.id)

    undone = undo(set.uuid)
    expect(undone).to be_ok
    expect(other.reload).to have_attributes(status: "active", obsoleted_at: nil, obsolescence_reason: nil)
    expect(row.reload.status).to eq("active")

    expect(undo(undone.change_set.uuid)).to be_ok
    expect(other.reload.status).to eq("obsolete")
    expect(row.reload.status).to eq("approved")
  end

  it "answers a conflict when the retired observation changed since" do
    applied = CompactionReviewService.apply(row.row_uuid, { keep_observation_id: kept.id })
    other.reload.update!(content: "SynthWidget does not support dark mode (edited).")

    result = undo(applied[:change_set_uuid])

    expect(result.status).to eq(:conflict)
    expect(result.conflicts.sole).to include("changed since")
    expect(row.reload.status).to eq("approved")
  end
end
