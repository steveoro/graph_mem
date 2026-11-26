# frozen_string_literal: true

require "rails_helper"

# Dream State R1c: the MCP review tools list a relation_review row like any other kind, and
# apply_maintenance_review answers a validation error for it; no tool name, parameter or schema changes.
RSpec.describe "relation_review through the MCP review tools", type: :model do
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:uses) { MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on") }
  let!(:fact) { fs_observe!(app, "SynthApp no longer uses SynthLib.") }
  let!(:row) do
    item = CompactionReviewApplier::RelationReview.item(RemovalEvidence.edges(after_id: 0, limit: 10).sole, fact)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end

  it "lists the row with its payload keys" do
    item = ListMaintenanceReviewTool.new.call(kind: "relation_review")[:items].sole

    expect(item[:payload].keys).to match_array(%w[kind relation_id relation_type from_entity_id from_name to_entity_id to_name evidence reason])
    expect(item[:payload]["evidence"]).to include("observation_id" => fact.id, "entity_name" => "SynthApp", "excerpt" => fact.content)
  end

  it "previews with dry_run as not applicable" do
    preview = ApplyMaintenanceReviewTool.new.call(item_id: row.row_uuid, dry_run: true)

    expect(preview).to include(dry_run: true, kind: "relation_review")
    expect(preview[:preview]).to include(ok: false, warnings: [ CompactionReviewApplier::RelationReview::MESSAGE ])
  end

  it "answers a validation error on apply, with the informational next move, and writes nothing" do
    error = nil
    expect { ApplyMaintenanceReviewTool.new.call(item_id: row.row_uuid) }.to raise_error(McpGraphMemErrors::InvalidArguments) { |raised| error = raised }

    envelope = ToolError.envelope(error, tool_name: "apply_maintenance_review")
    expect(envelope).to include("category" => "validation", "retriable" => false,
                                "message" => "ending a relation arrives with the relation lifecycle; remove the relation by hand if it is wrong",
                                "next_move" => CompactionReviewApplier::RelationReview::NEXT_MOVE)
    expect(row.reload.status).to eq("active")
    expect(MemoryRelation.exists?(uses.id)).to be(true)
  end
end
