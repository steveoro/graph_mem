# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeSetUndo::ReviewRows do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let(:item) do
    {
      id: "relation-1", kind: "relationship_proposal",
      from_entity_id: alpha.id, to_entity_id: beta.id, relation_type: "depends_on",
      confidence_band: "high", score: 11, explanation: "synthetic"
    }
  end
  let!(:row) { CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).first }

  def latest_uuid
    ChangeSet.order(:id).last.uuid
  end

  def undo(uuid)
    ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")
  end

  it "undoes a dismiss: the row is active again and its suppressions are gone; redo dismisses again" do
    CompactionReviewService.dismiss(row.row_uuid, reason: "synthetic")
    dismiss_uuid = latest_uuid
    signatures = MaintenanceReportSuppression.pluck(:signature)
    expect(signatures).not_to be_empty

    undo_result = undo(dismiss_uuid)
    expect(undo_result).to be_ok
    expect(row.reload).to have_attributes(status: "active", dismissed_at: nil, resolution_reason: nil)
    expect(MaintenanceReportSuppression.count).to eq(0)

    expect(undo(undo_result.change_set.uuid)).to be_ok
    expect(row.reload).to have_attributes(status: "dismissed", resolution_reason: "synthetic")
    expect(MaintenanceReportSuppression.pluck(:signature)).to match_array(signatures)
  end

  it "undoes a restore: the row is dismissed again and its suppressions come back" do
    CompactionReviewService.dismiss(row.row_uuid, reason: "synthetic")
    suppressions = MaintenanceReportSuppression.order(:id).map { |s| s.attributes.except("updated_at") }
    CompactionReviewService.restore(row.row_uuid)
    expect(MaintenanceReportSuppression.count).to eq(0)

    expect(undo(latest_uuid)).to be_ok
    expect(row.reload.status).to eq("dismissed")
    expect(MaintenanceReportSuppression.order(:id).map { |s| s.attributes.except("updated_at") }).to eq(suppressions)
  end

  it "undoes an apply: the relation it created is removed and the row is active again" do
    CompactionReviewService.apply(row.row_uuid)
    expect(MemoryRelation.where(from_entity_id: alpha.id, to_entity_id: beta.id)).to exist
    expect(row.reload.status).to eq("approved")

    expect(undo(latest_uuid)).to be_ok
    expect(MemoryRelation.where(from_entity_id: alpha.id, to_entity_id: beta.id)).not_to exist
    expect(row.reload).to have_attributes(status: "active", applied_at: nil)
  end

  it "skips (and reports) a row that changed since, or that the cleanup job deleted" do
    CompactionReviewService.ignore(row.row_uuid)
    ignore_uuid = latest_uuid
    row.update!(status: "dismissed")

    result = undo(ignore_uuid)
    expect(result).to be_ok
    expect(result.message).to include("skipped: review row #{row.row_uuid.first(8)} is now dismissed")
    expect(row.reload.status).to eq("dismissed")

    CompactionReviewService.restore(row.row_uuid)
    restore_uuid = latest_uuid
    row.destroy!
    expect(undo(restore_uuid).message).to include("was deleted")
  end
  it "restores resolved_by, change_set_id and expires_at" do
    CompactionReviewService.snooze(row.row_uuid, days: 10)
    snoozed = row.reload.attributes.slice("expires_at", "change_set_id")
    CompactionReviewService.dismiss(row.row_uuid, reason: "synthetic")
    expect(row.reload).to have_attributes(resolved_by: "generator", expires_at: nil)

    expect(undo(latest_uuid)).to be_ok
    expect(row.reload).to have_attributes(status: "ignored", resolved_by: nil, change_set_id: snoozed["change_set_id"])
    expect(row.expires_at).to be_within(0.001).of(snoozed["expires_at"])
  end

  it "still undoes a set recorded by 1.57.0 (review fields without the UI-5a keys)" do
    set = ChangeSet.record(kind: "review.dismiss") do |context|
      row.update!(status: "dismissed", dismissed_at: Time.current, resolved_by: "operator")
      context.note_review_row!(row, before: { "status" => "active", "applied_at" => nil, "dismissed_at" => nil, "resolution_reason" => nil },
                                    after: { "status" => "dismissed" })
      context.uuid
    end

    expect(undo(set)).to be_ok
    expect(row.reload).to have_attributes(status: "active", dismissed_at: nil, resolved_by: "operator")
  end
end
