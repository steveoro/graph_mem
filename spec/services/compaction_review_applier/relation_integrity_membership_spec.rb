# frozen_string_literal: true

require "rails_helper"

# A relation_integrity row that deletes a part_of (a merge collision's extra parent) syncs the
# child to the parent it keeps, under the lock CompactionReviewService.apply holds.
RSpec.describe "relation_integrity apply and membership" do
  let(:suffix) { SecureRandom.hex(3) }
  let(:alpha) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }
  let(:beta) { MemoryEntity.create!(name: "Beta Project #{suffix}", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "integrity_sweep" }) }

  def collision_row(keep, extra)
    payload = { "issue_kind" => "merge_collision",
                "payload" => { "kind" => "merge_collision", "child_entity_id" => widget.id, "keep_id" => keep.id,
                               "delete_ids" => [ extra.id ] } }
    MaintenanceReportRow.create!(maintenance_report: report, report_type: "compaction_review", row_uuid: SecureRandom.uuid,
                                 kind: "relation_integrity", status: "active", payload: payload,
                                 signature: CompactionReviewService.signature_for("relation_integrity", payload))
  end

  # Two parents, as rows written before the single-parent check: the second one by update_column.
  def two_parents
    keep = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    extra = MemoryRelation.create!(from_entity: widget, to_entity: beta, relation_type: "synth_placeholder")
    extra.update_column(:relation_type, "part_of")
    widget.update_column(:project_id, beta.id)
    [ keep, extra ]
  end

  it "deletes the extra parent and moves the child to the kept parent's project" do
    keep, extra = two_parents

    result = CompactionReviewService.apply(collision_row(keep, extra).row_uuid, {})

    expect(result[:success]).to be(true)
    expect(MemoryRelation.exists?(extra.id)).to be(false)
    expect(widget.reload.project_id).to eq(alpha.id)
  end

  # Drift is this example's point: the refused repair leaves the child's second parent in place.
  it "refuses a name collision in the kept parent's project, with nothing deleted", membership_drift: :allowed do
    keep, extra = two_parents
    fs_member!(alpha, widget.name)

    result = CompactionReviewService.apply(collision_row(keep, extra).row_uuid, {})

    expect(result).to include(success: false, error: include("already exists there"))
    expect(MemoryRelation.exists?(extra.id)).to be(true)
    expect(widget.reload.project_id).to eq(beta.id)
  end
end
