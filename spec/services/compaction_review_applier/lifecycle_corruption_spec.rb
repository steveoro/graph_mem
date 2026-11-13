# frozen_string_literal: true

require "rails_helper"

# 1.86.0 (B1): Repair of a `lifecycle_corruption` row. The rows come from the integrity sweep, and
# the corrupt states are written with update_columns (the model validation refuses them), like the
# production chain: a supersede whose replacement was deleted by GC, the FK nulling superseded_by.
RSpec.describe CompactionReviewApplier::LifecycleCorruption do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:fact) { fs_fact!(widget, "SynthWidget renders with the canvas backend.") }
  let!(:old) { fs_observe!(widget, "SynthWidget renders with the SVG backend.") }

  def corrupt!(observation, **columns)
    observation.update_columns(columns)
    observation
  end

  # The production shape (#4217): superseded, superseded_by NULL, outdated_by a same-entity source fact.
  def superseded_without_link!(outdated_by: fact)
    corrupt!(old, status: "superseded", obsoleted_at: 2.days.ago.change(usec: 0), outdated_by_id: outdated_by&.id,
                  obsolescence_reason: "Outdated by source fact ##{fact.id}", superseded_by_id: nil)
  end

  # Seeds rows the way DreamStateCompactionJob#queue_integrity_issues does.
  def sweep_rows
    issues = GraphIntegrityService.new.send(:detect_observation_lifecycle_corruption)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "integrity_sweep",
                                        items: issues.map { |issue| issue.merge(id: SecureRandom.uuid) })
  end

  def apply(row) = Current.set(actor: FactSupersedeHelpers::OPERATOR_ACTOR) { CompactionReviewService.apply(row.row_uuid, {}) }
  def undo(uuid) = ChangeSetUndo.call(uuid, actor: FactSupersedeHelpers::OPERATOR_ACTOR)

  it "points a superseded row without superseded_by at its active same-entity outdated_by fact, and undo restores it" do
    superseded_without_link!
    row = sweep_rows.sole
    obsoleted_at = old.reload.obsoleted_at

    result = apply(row)

    expect(result).to include(success: true, message: include("##{old.id}", "##{fact.id}"))
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: fact.id, outdated_by_id: fact.id,
                                          obsoleted_at: obsoleted_at)
    expect(old).to be_valid
    set = ChangeSet.find_by!(uuid: result[:change_set_uuid])
    expect(set).to have_attributes(kind: "review.apply", undo_strategy: "audit")
    expect(row.reload.status).to eq("approved")

    expect(undo(set.uuid)).to be_ok
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: nil, outdated_by_id: fact.id)
    expect(row.reload.status).to eq("active")
  end

  it "marks it obsolete when there is no outdated_by, keeping obsoleted_at and the reason; undo restores it" do
    superseded_without_link!(outdated_by: nil)
    row = sweep_rows.sole
    obsoleted_at = old.reload.obsoleted_at

    result = apply(row)

    expect(result).to include(success: true, message: include("obsolete"))
    expect(old.reload).to have_attributes(status: "obsolete", superseded_by_id: nil, obsoleted_at: obsoleted_at,
                                          obsolescence_reason: "Outdated by source fact ##{fact.id}")
    expect(undo(result[:change_set_uuid])).to be_ok
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: nil)
  end

  it "marks it obsolete, keeping outdated_by, when the outdated_by fact is no longer active" do
    superseded_without_link!
    row = sweep_rows.sole
    fact.mark_obsolete!(reason: "retired")

    expect(apply(row)).to include(success: true)
    expect(old.reload).to have_attributes(status: "obsolete", outdated_by_id: fact.id, superseded_by_id: nil)
  end

  it "clears obsoleted_at and the stale reason of an active row; undo restores them" do
    corrupt!(old, obsoleted_at: 3.days.ago.change(usec: 0), obsolescence_reason: "stale reason")
    row = sweep_rows.sole

    result = apply(row)

    expect(result).to include(success: true)
    expect(old.reload).to have_attributes(status: "active", obsoleted_at: nil, obsolescence_reason: nil)
    expect(undo(result[:change_set_uuid])).to be_ok
    expect(old.reload).to have_attributes(status: "active", obsolescence_reason: "stale reason")
    expect(old.obsoleted_at).to be_present
  end

  it "undoes the repair of an active row that also carried outdated_by and superseded_by" do
    replacement = fs_observe!(widget, "SynthWidget renders with the WebGL backend.")
    corrupt!(old, obsoleted_at: 3.days.ago.change(usec: 0), obsolescence_reason: "stale reason",
                  outdated_by_id: fact.id, superseded_by_id: replacement.id)
    row = sweep_rows.sole

    result = apply(row)
    expect(result).to include(success: true)
    expect(old.reload).to have_attributes(status: "active", obsoleted_at: nil, outdated_by_id: nil, superseded_by_id: nil)

    expect(undo(result[:change_set_uuid])).to be_ok
    expect(old.reload).to have_attributes(status: "active", obsolescence_reason: "stale reason", outdated_by_id: fact.id,
                                          superseded_by_id: replacement.id)
    expect(row.reload.status).to eq("active")
  end

  it "refuses a cross-entity superseded_by and changes nothing" do
    beta = fs_member!(gadget, "Beta Service")
    elsewhere = fs_observe!(beta, "Beta Service renders with the canvas backend.")
    corrupt!(old, status: "superseded", obsoleted_at: 1.day.ago, superseded_by_id: elsewhere.id)
    row = sweep_rows.sole

    expect(CompactionReviewApplier.preview(row)).to include(ok: false, warnings: include(include("another entity")))
    expect(apply(row)).to include(success: false, error: include("another entity", "Dismiss"))
    expect(old.reload).to have_attributes(status: "superseded", superseded_by_id: elsewhere.id)
    expect(row.reload.status).to eq("active")
  end

  it "says already consistent when the issue no longer holds, and the Dangling policy dismisses it" do
    superseded_without_link!
    row = sweep_rows.sole
    expect(ReviewPolicies::DanglingCheck.reason(row)).to be_nil

    old.update_columns(superseded_by_id: fact.id)

    expect(ReviewPolicies::DanglingCheck.reason(row)).to include("already consistent")
    expect(CompactionReviewApplier.preview(row)).to include(ok: true, effects: [ include("already consistent") ])
    expect(apply(row)).to include(success: true, message: include("already consistent"))
  end

  it "previews each repair without writing" do
    superseded_without_link!
    row = sweep_rows.sole

    preview = CompactionReviewApplier.preview(row)

    expect(preview).to include(ok: true, undo: CompactionReviewApplier::Preview::UNDO_AUDIT,
                               effects: [ include("superseded_by", "##{fact.id}") ])
    expect(old.reload.superseded_by_id).to be_nil
  end
end
