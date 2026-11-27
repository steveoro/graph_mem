# frozen_string_literal: true

require "rails_helper"

# Dream State R1b: the `swap` and `add` operations of a relation_retype row. A swap turns a
# library's part_of a Project into the Project's depends_on it, and the library (with its own
# part_of subtree) leaves the project's scope; an add creates the depends_on for an orphan.
RSpec.describe CompactionReviewApplier::RelationRetypeDependency do
  let(:operator) { "operator:synth@127.0.0.1" }
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { fs_member!(app, "SynthLib", "Gem") }
  let!(:notes) { fs_member!(library, "SynthLib Notes", "Documentation") }
  let!(:config) { fs_member!(library, "SynthLib Config", "Configuration") }
  let(:part_of) { MemoryRelation.find_by!(from_entity_id: library.id, to_entity_id: app.id, relation_type: "part_of") }

  def seed(item)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ item ]).sole
  end

  def swap_row(relation = part_of)
    names = MemoryEntity.where(id: [ relation.from_entity_id, relation.to_entity_id ]).pluck(:id, :name).to_h
    seed(described_class.swap_item(relation, names, evidence: { entity_type: "Gem", facts: [] }))
  end

  def apply(row) = Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid) }

  def scopes = [ library, notes, config ].map { |entity| entity.reload.project_id }

  def backfill_changes = ProjectIdBackfill.new(out: StringIO.new).run.changed

  describe "swap" do
    it "queues the R1b payload keys, with the stored part_of as relation and endpoints" do
      row = swap_row

      expect(row.payload).to include("operation" => "swap", "relation_id" => part_of.id, "from_entity_id" => library.id,
                                     "from_name" => "SynthLib", "to_entity_id" => app.id, "to_name" => "SynthApp",
                                     "old_type" => "part_of", "new_type" => "depends_on", "evidence" => { "entity_type" => "Gem", "facts" => [] })
      expect(row.payload["reason"]).to include("'SynthApp' depends_on 'SynthLib'")
      expect(row.signature).to eq("relation_retype|swap|#{part_of.id}|depends_on")
      expect(row.anchor_entity_id).to eq(library.id)
    end

    it "previews the swap and the scope it changes" do
      preview = CompactionReviewApplier.preview(swap_row)

      expect(preview).to include(ok: true, undo: "30 days")
      expect(preview[:effects]).to eq([ "Deletes 'SynthLib' part_of 'SynthApp' (##{part_of.id})", "Creates 'SynthApp' depends_on 'SynthLib'",
                                        "SynthLib and its 2 children leave SynthApp's scope (they become global)" ])
    end

    it "swaps the edge, makes the library and its subtree global, and undo and redo round-trip it" do
      row = swap_row
      relation_id = part_of.id

      result = apply(row)

      expect(result).to include(success: true, undoable: true)
      expect(result[:message]).to include("swapped for 'SynthApp' depends_on 'SynthLib'",
                                          "SynthLib and its 2 children leave SynthApp's scope")
      expect(MemoryRelation.exists?(relation_id)).to be(false)
      depends_on = MemoryRelation.find_by!(from_entity_id: app.id, to_entity_id: library.id, relation_type: "depends_on")
      expect(MemoryRelation.where(from_entity_id: library.id, relation_type: "part_of")).not_to exist
      expect(scopes).to eq([ nil, nil, nil ])
      expect(MemoryRelation.where(to_entity_id: library.id, relation_type: "part_of").pluck(:from_entity_id)).to contain_exactly(notes.id, config.id)
      expect(row.reload.status).to eq("approved")
      set = ChangeSet.find_by!(uuid: result[:change_set_uuid])
      expect(set.audit_logs.pluck(:auditable_type, :action)).to contain_exactly(%w[MemoryRelation delete], %w[MemoryRelation create])
      expect(backfill_changes).to eq(0)

      undo = ChangeSetUndo.call(result[:change_set_uuid], actor: operator)

      expect(undo).to be_ok
      expect(MemoryRelation.find(relation_id)).to have_attributes(from_entity_id: library.id, to_entity_id: app.id, relation_type: "part_of")
      expect(MemoryRelation.exists?(depends_on.id)).to be(false)
      expect(scopes).to eq([ app.id, app.id, app.id ])
      expect(row.reload.status).to eq("active")
      expect(backfill_changes).to eq(0)

      redone = ChangeSetUndo.call(undo.change_set.uuid, actor: operator)

      expect(redone).to be_ok
      expect(MemoryRelation.exists?(relation_id)).to be(false)
      expect(MemoryRelation.exists?(from_entity_id: app.id, to_entity_id: library.id, relation_type: "depends_on")).to be(true)
      expect(scopes).to eq([ nil, nil, nil ])
      expect(backfill_changes).to eq(0)
    end

    it "keeps a depends_on that already exists and only removes the part_of" do
      existing = MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on")

      expect(apply(swap_row)).to include(success: true)
      expect(MemoryRelation.where(from_entity_id: app.id, to_entity_id: library.id).pluck(:id)).to eq([ existing.id ])
      expect(scopes).to eq([ nil, nil, nil ])
    end

    it "refuses a library whose name a global entity of its type holds, and queues one entity_merge for the two" do
      global = MemoryEntity.create!(name: "SynthLib", entity_type: "Gem")
      row = swap_row

      result = apply(row)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq("Cannot swap 'SynthLib' out of its project: a global Gem 'SynthLib' (##{global.id}) already has " \
                                   "its name. An entity_merge suggestion (the global one into this one) is queued: merge them, then " \
                                   "apply this row again")
      expect(part_of.reload.relation_type).to eq("part_of")
      expect(scopes).to eq([ app.id, app.id, app.id ])
      expect(MemoryRelation.where(from_entity_id: app.id, relation_type: "depends_on")).not_to exist
      expect(row.reload).to have_attributes(status: "active", resolution_reason: result[:error])
      merge = MaintenanceReportRow.find_by!(kind: "entity_merge")
      expect(merge.payload).to include("entity_a" => include("entity_id" => global.id), "entity_b" => include("entity_id" => library.id),
                                       "recommendation" => "review_manually")
      expect(merge.signature).to eq("entity_merge|#{[ library.id, global.id ].sort.join('-')}")

      expect(apply(row)[:success]).to be(false)
      expect(MaintenanceReportRow.where(kind: "entity_merge").count).to eq(1)
      expect(CompactionReviewApplier.preview(row)).to include(ok: false, warnings: [ result[:error] ])
    end

    it "applies after the operator merged the two libraries: one global node, depended on" do
      global = MemoryEntity.create!(name: "SynthLib", entity_type: "Gem")
      other = fs_project!("SynthOther")
      MemoryRelation.create!(from_entity: other, to_entity: global, relation_type: "depends_on")
      row = swap_row
      apply(row)
      merge = MaintenanceReportRow.find_by!(kind: "entity_merge")

      expect(Current.set(actor: operator) { CompactionReviewService.apply(merge.row_uuid) }).to include(success: true)
      expect(apply(row)).to include(success: true)

      expect(MemoryEntity.where(name: "SynthLib").pluck(:id, :project_id)).to eq([ [ library.id, nil ] ])
      expect(MemoryRelation.where(to_entity_id: library.id, relation_type: "depends_on").pluck(:from_entity_id)).to contain_exactly(app.id, other.id)
      expect([ notes, config ].map { |child| child.reload.project_id }).to eq([ nil, nil ])
      expect(backfill_changes).to eq(0)
    end

    it "refuses without a merge suggestion when the global namesake has another type" do
      MemoryEntity.create!(name: "SynthLib", entity_type: "Tool")

      result = apply(swap_row)

      expect(result[:error]).to include("a global Tool 'SynthLib'", "a merge needs one type")
      expect(MaintenanceReportRow.where(kind: "entity_merge")).not_to exist
      expect(scopes).to eq([ app.id, app.id, app.id ])
    end

    it "refuses naming the child whose name is taken globally, and queues nothing" do
      MemoryEntity.create!(name: "SynthLib Notes", entity_type: "Task")
      row = swap_row

      result = apply(row)

      expect(result[:error]).to eq("Cannot swap 'SynthLib' out of its project: its child 'SynthLib Notes' has a name already taken in the " \
                                   "global scope. Rename or move that child first, then apply this row again")
      expect(MaintenanceReportRow.where.not(kind: "relation_retype")).not_to exist
      expect(part_of.reload).to be_present
      expect(scopes).to eq([ app.id, app.id, app.id ])
    end

    it "answers stale rows like R1a: done when already swapped, an error when the edge is gone or changed" do
      row = swap_row
      relation_id = part_of.id
      expect(apply(row)).to include(success: true)
      row.update_columns(status: "active")

      expect(apply(row)).to include(success: true, message: "Nothing to do: relation ##{relation_id} is already swapped for a depends_on")

      MemoryRelation.where(from_entity_id: app.id, relation_type: "depends_on").destroy_all
      row.update_columns(status: "active")
      expect(apply(row)).to include(success: false, error: "Cannot swap relation ##{relation_id}: it no longer exists; dismiss this row")
      expect(ReviewPolicies::DanglingCheck.reason(row)).to eq("relation ##{relation_id} gone")
    end

    it "refuses a row whose edge is no longer part_of" do
      row = swap_row
      part_of.update_column(:relation_type, "relates_to")
      ProjectMembership.sync!(library)

      expect(apply(row)[:error]).to eq("Cannot swap relation ##{part_of.id}: it is relates_to now, no longer part_of; dismiss this row")
      expect(ReviewPolicies::DanglingCheck.reason(row)).to eq("relation ##{part_of.id} is no longer part_of")
    end
  end

  describe "add" do
    let!(:orphan) { MemoryEntity.create!(name: "SynthTool", entity_type: "Tool") }

    def add_row
      seed(described_class.add_item(app, orphan, evidence: { entity_type: "Tool", score: 10, matched_tokens: %w[synth] }))
    end

    it "queues the R1b payload keys, with no relation and the edge to create as endpoints" do
      row = add_row

      expect(row.payload).to include("operation" => "add", "relation_id" => nil, "old_type" => nil, "new_type" => "depends_on",
                                     "from_entity_id" => app.id, "to_entity_id" => orphan.id,
                                     "evidence" => { "entity_type" => "Tool", "score" => 10, "matched_tokens" => %w[synth] })
      expect(row.signature).to eq("relation_retype|add|#{app.id}-#{orphan.id}|depends_on")
      expect(row.anchor_entity_id).to eq(orphan.id)
    end

    it "creates the project's depends_on with no membership change" do
      row = add_row
      expect(CompactionReviewApplier.preview(row)).to include(ok: true, effects: [ "Creates 'SynthApp' depends_on 'SynthTool'",
                                                                                   "No membership change: 'SynthTool' keeps the global scope" ])

      result = apply(row)

      expect(result).to include(success: true)
      expect(result[:message]).to start_with("Created 'SynthApp' depends_on 'SynthTool'")
      expect(MemoryRelation.exists?(from_entity_id: app.id, to_entity_id: orphan.id, relation_type: "depends_on")).to be(true)
      expect(orphan.reload.project_id).to be_nil

      row.update_columns(status: "active")
      expect(apply(row)).to include(success: true, message: "Nothing to do: 'SynthApp' depends_on 'SynthTool' exists")
      expect(ReviewPolicies::DanglingCheck.reason(row)).to eq("relation already exists")
    end

    it "answers an endpoint that is gone with an error asking to dismiss" do
      row = add_row
      orphan.destroy!

      expect(apply(row)).to include(success: false, error: "Cannot add the depends_on: entity ##{orphan.id} no longer exists; dismiss this row")
      expect(ReviewPolicies::DanglingCheck.reason(row)).to eq("entity ##{orphan.id} gone")
    end
  end

  it "keeps relation_retype rows out of bulk apply" do
    row = swap_row

    result = CompactionReviewService.bulk_apply([ row.row_uuid ])

    expect(result[:message]).to include("1 skipped (not bulk-applicable")
    expect(part_of.reload).to be_present
  end
end
