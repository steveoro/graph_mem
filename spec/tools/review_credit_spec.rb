# frozen_string_literal: true

require "rails_helper"

# Audit actor (1.65.0, B4): with the actor set for MCP calls, a review row applied or dismissed
# through the maintenance tools is credited to the agent (it used to be "generator"); the
# operator UI still credits the operator.
RSpec.describe "Review credit through MCP", type: :request do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Component") }

  def proposal
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test",
                                        items: [ { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: widget.id,
                                                   to_entity_id: alpha.id, relation_type: "depends_on", confidence_band: "high", score: 14 } ]).sole
  end

  # The tool path an MCP call takes, on the maintenance profile.
  def call_tool(tool_class, **args)
    context = GraphMem::OfficialMcp::RequestContext::Context.new(client_id: "synth-client-a", profile: :maintenance, session_id: nil, client_info: nil)
    context.around_call { tool_class.new(headers: context.headers).call_with_schema_validation!(**args) }
  end

  it "credits the agent for apply_maintenance_review and dismiss_maintenance_review" do
    applied = proposal
    call_tool(ApplyMaintenanceReviewTool, item_id: applied.row_uuid)
    expect(applied.reload).to have_attributes(status: "approved", resolved_by: "agent")
    expect(ChangeSet.find(applied.change_set_id).actor).to eq("mcp:apply_maintenance_review")

    MaintenanceReportRow.delete_all
    dismissed = proposal
    call_tool(DismissMaintenanceReviewTool, item_id: dismissed.row_uuid, action: "dismiss")
    expect(dismissed.reload).to have_attributes(status: "dismissed", resolved_by: "agent")
  end

  it "still credits the operator through the Review page" do
    row = proposal
    sign_in_operator

    post review_row_apply_path(row.row_uuid)

    expect(row.reload).to have_attributes(status: "approved", resolved_by: "operator")
  end
end
