# frozen_string_literal: true

require "rails_helper"

# UI-5b C1: the preview says what apply would do, and writes nothing.
RSpec.describe CompactionReviewApplier, ".preview" do
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:twin) { MemoryEntity.create!(name: "Synth Widget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  def row(kind, payload)
    MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: kind, status: "active",
                                 signature: "#{kind}|#{SecureRandom.hex(4)}", payload: payload, group_key: "#{kind}|spec")
  end

  def counts
    [ AuditLog.count, ChangeSet.count, MaintenanceReportRow.where(status: "active").count, MaintenanceReportSuppression.count,
      MemoryRelation.count, MemoryObservation.active.count, MemoryEntity.count ]
  end

  # Previews, checks nothing was written, then applies and returns both.
  def preview_then_apply(review_row, params = {})
    before = counts
    preview = described_class.preview(review_row, params)
    expect(counts).to eq(before)
    [ preview, CompactionReviewService.apply(review_row.row_uuid, params) ]
  end

  it "previews a merge with the counts merge_into then moves" do
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders tiles.")
    MemoryRelation.create!(from_entity: widget, to_entity: beta, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: twin, to_entity: beta, relation_type: "depends_on")
    merge = row("entity_merge", { "entity_a" => { "entity_id" => widget.id }, "entity_b" => { "entity_id" => twin.id } })

    preview, applied = preview_then_apply(merge)

    expect(preview).to include(ok: true, undo: "7 days")
    expect(preview[:effects]).to include("1 observation(s) move to the target", "0 relation(s) re-pointed, 1 dropped as duplicates")
    expect(applied[:success]).to be(true)
    expect(twin.memory_observations.count).to eq(1)
  end

  it "previews a reparent with the subtree size and the new scope" do
    child = MemoryEntity.create!(name: "SynthWidget part", entity_type: "Component")
    MemoryRelation.create!(from_entity: child, to_entity: widget, relation_type: "part_of")
    move = row("reparent_entity", { "entity_id" => widget.id, "parent_id" => project.id })

    preview, applied = preview_then_apply(move)

    expect(preview[:effects]).to eq([ "Moves 'SynthWidget' (2 entities) under 'Alpha Service'", "Scope becomes project 'Alpha Service'" ])
    expect(applied[:success]).to be(true)
    expect(child.reload.project_id).to eq(project.id)
  end

  it "previews relation deletes, observation obsolete marks, stale memory and relationship proposals" do
    relation = MemoryRelation.create!(from_entity: widget, to_entity: beta, relation_type: "depends_on")
    fact = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget is old.", valid_until: 1.day.ago)
    cases = {
      row("delete_relation", { "relation_id" => relation.id }) => "Deletes 'SynthWidget' depends_on 'Beta Service' (##{relation.id})",
      row("delete_observation", { "observation_id" => fact.id }) => "Observation ##{fact.id} marked obsolete",
      row("relationship_proposal", { "from_entity_id" => twin.id, "to_entity_id" => beta.id, "relation_type" => "relates_to" }) =>
        "Creates 'Synth Widget' relates_to 'Beta Service'"
    }
    cases.each do |review_row, effect|
      preview, applied = preview_then_apply(review_row)
      expect(preview).to include(ok: true, undo: "30 days")
      expect(preview[:effects]).to include(effect)
      expect(applied[:success]).to be(true), applied.inspect
    end

    stale_fact = MemoryObservation.create!(memory_entity: beta, content: "Beta Service expired.", valid_until: 1.day.ago)
    stale = row("stale_memory", { "entity_id" => beta.id, "observation_ids" => [ stale_fact.id ], "signal" => "valid_until_elapsed" })
    preview, = preview_then_apply(stale)
    expect(preview[:effects]).to eq([ "1 observation(s) marked obsolete" ])
    expect(stale_fact.reload.status).to eq("obsolete")
  end

  it "previews each side of a contradiction, and the chosen side when given" do
    kept = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget is fast.")
    other = MemoryObservation.create!(memory_entity: beta, content: "SynthWidget is not fast.")
    pair = row("contradiction", { "observation_id_1" => kept.id, "observation_id_2" => other.id })

    both = described_class.preview(pair)
    expect(both[:effects]).to eq([ "Keep ##{kept.id}: ##{other.id} marked obsolete", "Keep ##{other.id}: ##{kept.id} marked obsolete" ])

    preview, applied = preview_then_apply(pair, { keep_observation_id: other.id })
    expect(preview).to include(ok: true, undo: "30 days", effects: [ "Keep ##{other.id}: ##{kept.id} marked obsolete" ])
    expect(applied[:success]).to be(true)
    expect(kept.reload.status).to eq("obsolete")

    expect(described_class.preview(pair.reload, { keep_observation_id: other.id })[:warnings])
      .to eq([ "Observation ##{kept.id} is no longer active (obsolete)" ])
  end

  it "says a delete_entity can't be undone" do
    preview = described_class.preview(row("delete_entity", { "entity_id" => beta.id }))

    expect(preview).to include(ok: true, undo: "not undoable: hard delete", warnings: [ "Can't be undone" ])
  end

  it "returns the preview from apply_maintenance_review dry_run" do
    proposal = row("relationship_proposal", { "from_entity_id" => widget.id, "to_entity_id" => beta.id, "relation_type" => "depends_on" })

    result = ApplyMaintenanceReviewTool.new.call(item_id: proposal.row_uuid, dry_run: true)

    expect(result[:preview]).to include(ok: true, effects: [ "Creates 'SynthWidget' depends_on 'Beta Service'" ])
    expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: beta.id)).not_to exist
  end
  # 1.86.2: compaction queues orphan rows with suggested_parents only (no parent_id).
  describe "an orphan_parent row with suggestions only" do
    let!(:alpha) { MemoryEntity.create!(name: "synth-alpha-project", entity_type: "Project") }
    let!(:beta_project) { MemoryEntity.create!(name: "synth-beta-project", entity_type: "Project") }
    let!(:orphan) { MemoryEntity.create!(name: "synth-orphan-task", entity_type: "Task") }

    def orphan_row(edited: nil)
      row("orphan_parent", { "entity_id" => orphan.id, "entity_name" => orphan.name, "entity_type" => "Task",
                             "suggested_parents" => [ { "project_id" => alpha.id, "project_name" => alpha.name, "score" => 0.9 },
                                                      { "project_id" => beta_project.id, "project_name" => beta_project.name, "score" => 0.6 } ] })
        .tap { |review_row| review_row.update!(edited_payload: edited) if edited }
    end

    def parent_of(entity) = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of").pick(:to_entity_id)

    it "previews and applies under the top suggestion" do
      preview, applied = preview_then_apply(orphan_row)

      expect(preview).to include(ok: true)
      expect(preview[:effects].first).to eq("Moves 'synth-orphan-task' (1 entity) under 'synth-alpha-project'")
      expect(applied[:success]).to be(true)
      expect(parent_of(orphan)).to eq(alpha.id)
    end

    it "skips a suggestion whose project is gone" do
      review_row = orphan_row
      alpha.destroy!

      preview, applied = preview_then_apply(review_row)

      expect(preview[:effects].first).to eq("Moves 'synth-orphan-task' (1 entity) under 'synth-beta-project'")
      expect(applied[:success]).to be(true)
      expect(parent_of(orphan)).to eq(beta_project.id)
    end

    it "lets an explicit action_params parent_id and an edited parent_id win over the suggestions" do
      expect(described_class.preview(orphan_row, { parent_id: beta_project.id })[:effects].first).to end_with("under 'synth-beta-project'")
      expect(described_class.preview(orphan_row(edited: { "parent_id" => project.id }))[:effects].first).to end_with("under 'Alpha Service'")
      expect(described_class.orphan_parent_id(orphan_row(edited: { "parent_id" => project.id }).effective_payload, { "parent_id" => beta_project.id.to_s }))
        .to eq(beta_project.id)
    end

    it "keeps an edited parent that is gone, and refuses when every suggestion is gone" do
      gone = MemoryEntity.create!(name: "synth-gone-project", entity_type: "Project").tap(&:destroy!)
      expect(described_class.orphan_parent_id(orphan_row(edited: { "parent_id" => gone.id }).effective_payload)).to eq(gone.id)

      review_row = orphan_row
      [ alpha, beta_project ].each(&:destroy!)

      expect(described_class.orphan_parent_id(review_row.effective_payload)).to eq(0)
      expect(described_class.preview(review_row)).to include(ok: false, warnings: [ "Entity or parent not found" ])
    end

    it "returns ok: true from apply_maintenance_review dry_run without action_params, and writes nothing" do
      review_row = orphan_row
      before = counts

      result = ApplyMaintenanceReviewTool.new.call(item_id: review_row.row_uuid, dry_run: true)

      expect(result[:preview]).to include(ok: true)
      expect(result[:preview][:effects].first).to end_with("under 'synth-alpha-project'")
      expect(counts).to eq(before)
    end
  end
end
