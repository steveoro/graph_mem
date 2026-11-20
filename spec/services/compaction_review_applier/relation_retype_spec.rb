# frozen_string_literal: true

require "rails_helper"

# R1a (plan item 5): the `relation_retype` review row. RelationTypeSweep queues it for a stored
# variant whose canonical type is part_of; Apply creates the part_of through the normal create
# path under the membership lock and deletes the variant, in one change set.
RSpec.describe CompactionReviewApplier::RelationRetype do
  let(:suffix) { SecureRandom.hex(3) }
  let(:project) { MemoryEntity.create!(name: "Alpha Project #{suffix}", entity_type: "Project") }
  let(:other_project) { MemoryEntity.create!(name: "Beta Project #{suffix}", entity_type: "Project") }
  let(:widget) { MemoryEntity.create!(name: "SynthWidget #{suffix}", entity_type: "Component") }
  let(:operator) { "operator:synth@127.0.0.1" }

  def stored_relation(from, to, stored_type, **attributes)
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}",
                                      **attributes)
    relation.update_column(:relation_type, stored_type)
    relation
  end

  # Queues the row the way production does: through the sweep.
  def queued_row(from = widget, to = project, stored_type = "child_of", **attributes)
    variant = stored_relation(from, to, stored_type, **attributes)
    RelationTypeSweep.call
    [ variant, MaintenanceReportRow.find_by!(kind: "relation_retype", signature: "relation_retype|retype|#{variant.id}|part_of") ]
  end

  def apply(row, params = {}) = Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid, params) }

  it "replaces the variant with a part_of through the create path, syncs membership, and undo restores the variant" do
    variant, row = queued_row(weight: 0.6, confidence: 0.8, properties: { "via" => "synth scan" })

    result = apply(row)

    expect(result).to include(success: true, undoable: true)
    expect(result[:message]).to include("Relation ##{variant.id} 'child_of' replaced by part_of")
    expect(MemoryRelation.exists?(variant.id)).to be(false)
    part_of = MemoryRelation.find_by!(from_entity_id: widget.id, to_entity_id: project.id, relation_type: "part_of")
    expect(part_of).to have_attributes(weight: 0.6, confidence: 0.8, properties: { "via" => "synth scan" })
    expect(widget.reload.project_id).to eq(project.id)
    expect(row.reload.status).to eq("approved")
    set = ChangeSet.find_by!(uuid: result[:change_set_uuid])
    expect(set.kind).to eq("review.apply")
    expect(set.audit_logs.pluck(:auditable_type, :action)).to contain_exactly(%w[MemoryRelation delete], %w[MemoryRelation create])

    undo = ChangeSetUndo.call(result[:change_set_uuid], actor: operator)

    expect(undo).to be_ok
    expect(MemoryRelation.find(variant.id)).to have_attributes(relation_type: "child_of", weight: 0.6)
    expect(MemoryRelation.exists?(part_of.id)).to be(false)
    expect(widget.reload.project_id).to be_nil
    expect(row.reload.status).to eq("active")
  end

  it "leaves everything unchanged and asks to move or keep when the entity already has a part_of parent" do
    MemoryRelation.create!(from_entity: widget, to_entity: other_project, relation_type: "part_of")
    ProjectMembership.sync!(widget)
    variant, row = queued_row

    result = apply(row)

    expect(result[:success]).to be(false)
    expect(result[:error]).to start_with("A choice is required").and include("is already part_of '#{other_project.name}'", '"move"', '"keep"')
    expect(variant.reload.relation_type).to eq("child_of")
    expect(widget.reload.project_id).to eq(other_project.id)
    expect(row.reload).to have_attributes(status: "active", resolution_reason: result[:error])
  end

  it "refuses a part_of that would close a cycle" do
    MemoryRelation.create!(from_entity: project, to_entity: widget, relation_type: "part_of")
    variant, row = queued_row

    result = apply(row)

    expect(result[:error]).to include("Cannot retype relation ##{variant.id}:", "cycle")
    expect(variant.reload.relation_type).to eq("child_of")
  end

  it "refuses a name collision in the target project and rolls the edge back" do
    MemoryEntity.create!(name: widget.name, entity_type: "Component", project_id: project.id)
    variant, row = queued_row

    result = apply(row)

    expect(result[:error]).to include("Cannot retype relation ##{variant.id}:", "already exists there")
    expect(variant.reload.relation_type).to eq("child_of")
    expect(MemoryRelation.where(from_entity_id: widget.id, relation_type: "part_of")).to be_empty
    expect(widget.reload.project_id).to be_nil
  end

  it "treats a relation that is gone, or already part_of, as stale" do
    variant, row = queued_row
    variant.update_column(:relation_type, "Part_Of")

    expect(apply(row)).to include(success: true, message: "Nothing to do: relation ##{variant.id} is already part_of")
    expect(variant.reload.relation_type).to eq("Part_Of")

    gone, gone_row = queued_row(MemoryEntity.create!(name: "SynthGear #{suffix}", entity_type: "Component"), project, "contained_in")
    gone.destroy!
    expect(apply(gone_row)).to include(success: false, error: "Cannot retype relation ##{gone.id}: it no longer exists; dismiss this row")
  end

  it "refuses an operation this release can't apply" do
    _variant, row = queued_row
    row.update_column(:payload, row.payload.merge("operation" => "swap"))

    result = apply(row)

    expect(result).to include(success: false)
    expect(result[:error]).to eq("Invalid relation_retype operation 'swap': only retype can be applied in this release")
    expect(CompactionReviewApplier.preview(row.reload)).to include(ok: false, warnings: [ result[:error] ])
  end

  it "refuses edits, and dismiss suppresses it for the next sweep" do
    variant, row = queued_row

    expect(CompactionReviewService.edit_item(row.row_uuid, { "new_type" => "depends_on" }))
      .to include(success: false, error: include("Relation retype rows can't be edited"))
    expect(Current.set(actor: operator) { CompactionReviewService.dismiss(row.row_uuid, reason: "keep it") }).to include(success: true)
    RelationTypeSweep.call

    expect(MaintenanceReportRow.where(kind: "relation_retype").count).to eq(1)
    expect(variant.reload.relation_type).to eq("child_of")
  end

  it "previews the membership move" do
    _variant, row = queued_row

    preview = CompactionReviewApplier.preview(row)

    expect(preview).to include(ok: true, undo: "30 days")
    expect(preview[:effects].last).to eq("'#{widget.name}' (1 entity) joins project '#{project.name}'")
  end

  describe "never applied in bulk" do
    it "is refused by an auto-apply policy, even when its candidate query returns it" do
      _variant, row = queued_row
      policy = ReviewPolicies::AutoApplyRelationships.new
      allow(policy).to receive_messages(enabled?: true, eligible: MaintenanceReportRow.where(id: row.id))

      expect(policy.call).to include("acted" => 0, "refused" => 1)
      expect(row.reload.status).to eq("active")
    end

    it "is excluded from group apply and from bulk apply" do
      _variant, row = queued_row

      preview = ReviewGroupActions.preview(group_key: row.group_key, op: "apply")
      expect(preview[:excluded]).to contain_exactly(include(row_uuid: row.row_uuid, reason: "destructive: apply one by one"))
      expect(ReviewGroupActions.apply(group_key: row.group_key, row_uuids: [ row.row_uuid ], token: preview[:token]))
        .to include(success: false, status: :unprocessable)
      expect(CompactionReviewService.bulk_apply([ row.row_uuid ])[:message]).to include("1 skipped (not bulk-applicable")
      expect(row.reload.status).to eq("active")
    end
  end

  it "is classified on the child, in the endpoints' group" do
    _variant, row = queued_row

    expect(row).to have_attributes(group_key: "relation_retype|#{[ widget.id, project.id ].sort.join('-')}",
                                   anchor_entity_id: widget.id)
  end

  describe "Dangling policy" do
    def dangling(row) = ReviewPolicies::DanglingCheck.reason(row.reload)

    it "dismisses a row whose relation is gone, already part_of, twinned, or no longer mapped" do
      variant, row = queued_row
      expect(dangling(row)).to be_nil

      variant.update_column(:relation_type, "some_other_type")
      expect(dangling(row)).to eq("no longer flagged: 'some_other_type' maps to some_other_type")
      variant.update_column(:relation_type, "part_of")
      expect(dangling(row)).to eq("relation already part_of")
      variant.update_column(:relation_type, "child_of")
      MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of")
      expect(dangling(row)).to eq("part_of relation already exists")
      variant.destroy!
      expect(dangling(row)).to eq("relation ##{variant.id} gone")

      ReviewPolicies::Dangling.new.call
      expect(row.reload).to have_attributes(status: "dismissed", resolution_reason: "dangling: relation ##{variant.id} gone")
    end
  end
end
