# frozen_string_literal: true

require "rails_helper"

# A reparent_entity (or orphan_parent) row applies through NodeOperationsStrategy#move_to_parent
# inside the row's transaction: a refused sync must leave the old parent edge in place.
RSpec.describe "reparent_entity apply on a name collision" do
  let(:suffix) { SecureRandom.hex(3) }
  let(:alpha) { MemoryEntity.create!(name: "Alpha Service #{suffix}", entity_type: "Project") }
  let(:beta) { MemoryEntity.create!(name: "Beta Service #{suffix}", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }

  it "rolls the move back, with the old parent kept" do
    MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    ProjectMembership.sync!(widget)
    fs_member!(beta, widget.name, "Component")
    report = MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "project_scan" })
    payload = { "entity_id" => widget.id, "parent_id" => beta.id }
    row = MaintenanceReportRow.create!(maintenance_report: report, report_type: "compaction_review", row_uuid: SecureRandom.uuid,
                                       kind: "reparent_entity", status: "active", payload: payload,
                                       signature: CompactionReviewService.signature_for("reparent_entity", payload))

    result = CompactionReviewService.apply(row.row_uuid, {})

    expect(result).to include(success: false, error: include("already exists there"))
    expect(MemoryRelation.where(from_entity_id: widget.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ alpha.id ])
    expect(widget.reload.project_id).to eq(alpha.id)
  end
end
