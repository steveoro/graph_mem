# frozen_string_literal: true

require "rails_helper"

# A relation_retype row whose child already has another part_of parent: the plain Apply would give
# it a second parent, so the row offers "move under the target" or "keep the parent" through
# action_params.parent_choice (CompactionReviewApplier::RelationRetypeChoice).
RSpec.describe CompactionReviewApplier::RelationRetypeChoice do
  let(:suffix) { SecureRandom.hex(3) }
  let(:operator) { "operator:synth@127.0.0.1" }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service #{suffix}", entity_type: "Project") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service #{suffix}", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let!(:gadget) { MemoryEntity.create!(name: "SynthGadget #{suffix}", entity_type: "Component") }

  def part_of!(child, parent)
    MemoryRelation.create!(from_entity: child, to_entity: parent, relation_type: "part_of").tap { ProjectMembership.sync!(child) }
  end

  # The variant ("Is Part Of", stored before fold-on-write) from the widget to the gadget, queued by the sweep.
  def queued_row(weight: 0.4)
    variant = MemoryRelation.create!(from_entity: widget, to_entity: gadget, relation_type: "synth_placeholder", weight: weight)
    variant.update_column(:relation_type, "Is Part Of")
    RelationTypeSweep.call
    [ variant, MaintenanceReportRow.find_by!(kind: "relation_retype") ]
  end

  def apply(row, choice = nil)
    params = choice ? { "parent_choice" => choice } : {}
    Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid, params) }
  end

  def parents_of(entity) = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").pluck(:to_entity_id)

  before do
    part_of!(widget, alpha)
    part_of!(gadget, alpha)
  end

  it "says in the queued row that the child has a parent, and asks for a choice instead of failing" do
    variant, row = queued_row

    expect(row.payload["reason"]).to include("is already part_of '#{alpha.name}'", "move it under '#{gadget.name}'", "relates_to")
    expect(row.payload.keys).to include("operation", "relation_id", "old_type", "new_type")
    expect(row.payload["operation"]).to eq("retype")

    preview = CompactionReviewApplier.preview(row)
    expect(preview[:ok]).to be(false)
    expect(preview[:warnings].sole).to include("A choice is required", '"move"', '"keep"')
    result = apply(row)
    expect(result).to include(success: false, error: include("A choice is required"))
    expect([ variant.reload.relation_type, parents_of(widget) ]).to eq([ "Is Part Of", [ alpha.id ] ])
  end

  describe "move under the target" do
    it "replaces the parent within the same project, and undo restores the parent and the variant" do
      variant, row = queued_row

      expect(CompactionReviewApplier.preview(row, { "parent_choice" => "move" })[:effects])
        .to include("Stays in project '#{alpha.name}'")
      result = apply(row, "move")

      expect(result).to include(success: true, undoable: true)
      expect(parents_of(widget)).to eq([ gadget.id ])
      expect(MemoryRelation.exists?(variant.id)).to be(false)
      expect(MemoryRelation.find_by(from_entity_id: widget.id, to_entity_id: gadget.id).weight).to eq(0.4)
      expect(widget.reload.project_id).to eq(alpha.id)
      expect(row.reload.status).to eq("approved")

      expect(ChangeSetUndo.call(result[:change_set_uuid], actor: operator)).to be_ok
      expect(parents_of(widget)).to eq([ alpha.id ])
      expect(MemoryRelation.find(variant.id).relation_type).to eq("Is Part Of")
      expect(widget.reload.project_id).to eq(alpha.id)
      expect(row.reload.status).to eq("active")
    end

    it "moves the child and its subtree to the target's project, as the preview says, and undo moves them back" do
      MemoryRelation.where(from_entity_id: gadget.id).delete_all
      part_of!(gadget, beta)
      sub = MemoryEntity.create!(name: "SynthPart #{suffix}", entity_type: "Component")
      part_of!(sub, widget)
      _variant, row = queued_row

      expect(CompactionReviewApplier.preview(row, { "parent_choice" => "move" })[:effects])
        .to include("Moves 2 entities from project '#{alpha.name}' to project '#{beta.name}'")
      result = apply(row, "move")

      expect(result[:success]).to be(true)
      expect([ widget.reload.project_id, sub.reload.project_id ]).to eq([ beta.id, beta.id ])
      expect(ChangeSetUndo.call(result[:change_set_uuid], actor: operator)).to be_ok
      expect([ widget.reload.project_id, sub.reload.project_id ]).to eq([ alpha.id, alpha.id ])
    end

    it "refuses a cycle with nothing changed" do
      MemoryRelation.where(from_entity_id: gadget.id).delete_all
      part_of!(gadget, widget)
      variant, row = queued_row

      expect(CompactionReviewApplier.preview(row, { "parent_choice" => "move" })[:warnings].sole).to include("part_of cycle")
      expect(apply(row, "move")).to include(success: false, error: include("Cannot retype relation ##{variant.id}:", "cycle"))
      expect([ variant.reload.relation_type, parents_of(widget) ]).to eq([ "Is Part Of", [ alpha.id ] ])
    end

    it "refuses a name collision in the target's project with nothing changed" do
      MemoryRelation.where(from_entity_id: gadget.id).delete_all
      part_of!(gadget, beta)
      MemoryEntity.create!(name: widget.name, entity_type: "Component", project_id: beta.id)
      variant, row = queued_row

      expect(CompactionReviewApplier.preview(row, { "parent_choice" => "move" })[:warnings].sole).to include("already exists there")
      expect(apply(row, "move")).to include(success: false, error: include("already exists there"))
      expect([ variant.reload.relation_type, parents_of(widget), widget.reload.project_id ]).to eq([ "Is Part Of", [ alpha.id ], alpha.id ])
    end
  end

  describe "keep the parent" do
    it "retypes the variant to relates_to without touching membership, and undo restores its stored type" do
      variant, row = queued_row

      expect(CompactionReviewApplier.preview(row, { "parent_choice" => "keep" })[:effects])
        .to include("Retypes the variant ##{variant.id} from 'Is Part Of' to relates_to", "No membership change")
      result = apply(row, "keep")

      expect(result[:success]).to be(true)
      expect(variant.reload.relation_type).to eq("relates_to")
      expect([ parents_of(widget), widget.reload.project_id ]).to eq([ [ alpha.id ], alpha.id ])

      expect(ChangeSetUndo.call(result[:change_set_uuid], actor: operator)).to be_ok
      expect(variant.reload.relation_type).to eq("Is Part Of")
    end

    it "merges the variant into a relates_to twin with the sweep's rule, and undo restores both" do
      variant, row = queued_row(weight: 0.9)
      twin = MemoryRelation.create!(from_entity: widget, to_entity: gadget, relation_type: "relates_to", weight: 0.2)

      result = apply(row, "keep")

      expect(result[:message]).to include("merged into relates_to ##{twin.id}")
      expect(MemoryRelation.exists?(variant.id)).to be(false)
      expect(twin.reload.weight).to eq(0.9)

      expect(ChangeSetUndo.call(result[:change_set_uuid], actor: operator)).to be_ok
      expect([ MemoryRelation.find(variant.id).relation_type, twin.reload.weight ]).to eq([ "Is Part Of", 0.2 ])
    end
  end

  it "keeps the single Apply for a child with no other parent" do
    MemoryRelation.where(from_entity_id: widget.id).delete_all
    ProjectMembership.sync!(widget)
    variant, row = queued_row

    expect(row.payload["reason"]).not_to include("is already part_of")
    expect(CompactionReviewApplier.preview(row)[:ok]).to be(true)
    expect(apply(row)[:success]).to be(true)
    expect([ MemoryRelation.exists?(variant.id), parents_of(widget) ]).to eq([ false, [ gadget.id ] ])
  end

  it "is dismissed by the Dangling policy once the child was moved under the target by hand" do
    _variant, row = queued_row
    NodeOperationsStrategy.new.move_to_parent(widget.id, gadget.id)

    expect(ReviewPolicies::DanglingCheck.reason(row.reload)).to eq("part_of relation already exists")
  end

  describe "apply_maintenance_review" do
    it "answers a validation error naming the two options without a choice, and applies one passed in action_params" do
      variant, row = queued_row
      tool = ApplyMaintenanceReviewTool.new

      expect { tool.call(item_id: row.row_uuid) }
        .to raise_error(GraphMem::InvalidArgumentsError, /A choice is required.*action_params\.parent_choice "move".*"keep"/)
      expect(tool.call(item_id: row.row_uuid, dry_run: true, action_params: { "parent_choice" => "keep" })[:preview]).to include(ok: true)

      expect(tool.call(item_id: row.row_uuid, action_params: { "parent_choice" => "keep" })[:success]).to be(true)
      expect(variant.reload.relation_type).to eq("relates_to")
    end
  end
end
