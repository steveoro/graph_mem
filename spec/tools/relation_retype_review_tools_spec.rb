# frozen_string_literal: true

require "rails_helper"

# R1a: the MCP review tools list and apply a `relation_retype` row like any other kind, with the
# payload keys fixed by the plan; no tool name, parameter or schema changes.
RSpec.describe "relation_retype through the MCP review tools", type: :model do
  let(:suffix) { SecureRandom.hex(3) }
  let(:project) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let!(:variant) do
    relation = MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "synth_placeholder_#{suffix}")
    relation.update_column(:relation_type, "contained_in")
    relation
  end

  before { RelationTypeSweep.call }

  it "lists the row with the fixed payload keys" do
    result = ListMaintenanceReviewTool.new.call(kind: "relation_retype")

    expect(result[:total_count]).to eq(1)
    item = result[:items].sole
    expect(item[:kind]).to eq("relation_retype")
    expect(item[:payload].keys).to match_array(%w[kind operation relation_id from_entity_id from_name to_entity_id to_name
                                                  old_type new_type reason])
    expect(item[:payload]).to include("operation" => "retype", "relation_id" => variant.id, "old_type" => "contained_in",
                                      "new_type" => "part_of", "from_name" => widget.name, "to_name" => project.name)
  end

  it "previews with dry_run, then applies it" do
    item_id = MaintenanceReportRow.find_by!(kind: "relation_retype").row_uuid
    tool = ApplyMaintenanceReviewTool.new

    preview = tool.call(item_id: item_id, dry_run: true)
    expect(preview).to include(dry_run: true, kind: "relation_retype")
    expect(preview[:preview]).to include(ok: true)
    expect(MemoryRelation.exists?(variant.id)).to be(true)

    result = tool.call(item_id: item_id)

    expect(result[:success]).to be(true)
    expect(MemoryRelation.exists?(variant.id)).to be(false)
    expect(MemoryRelation.exists?(from_entity_id: widget.id, to_entity_id: project.id, relation_type: "part_of")).to be(true)
    expect(widget.reload.project_id).to eq(project.id)
  end

  it "answers an invalid-arguments error naming the two choices when the child already has a parent" do
    other = MemoryEntity.create!(name: "Beta Project #{suffix}", entity_type: "Project")
    fs_member!(other, widget)
    item_id = MaintenanceReportRow.find_by!(kind: "relation_retype").row_uuid

    expect { ApplyMaintenanceReviewTool.new.call(item_id: item_id) }
      .to raise_error(GraphMem::InvalidArgumentsError, /A choice is required: .*already part_of .*parent_choice "move".*"keep"/)
    expect(variant.reload.relation_type).to eq("contained_in")
  end
end
