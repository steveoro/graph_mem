# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReviewPolicyRunner do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Component") }

  # Classified rows (a group key), so the run's backfill keeps the confidence set here.
  def row(kind, payload, status: "active", **attrs)
    MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: kind, status: status,
                                 signature: "#{kind}|#{SecureRandom.hex(6)}", payload: payload,
                                 group_key: "#{kind}|spec-#{SecureRandom.hex(3)}", **attrs)
  end

  def proposal(from, to, band: "high", type: "depends_on", **attrs)
    row("relationship_proposal", { "from_entity_id" => from.id, "to_entity_id" => to.id, "relation_type" => type,
                                   "confidence_band" => band, "score" => 14 }, **attrs)
  end

  def run = described_class.call(trigger: "spec")

  def set_setting(var, value)
    setting = AppSettings.find_or_initialize_by(var: var)
    setting.value = value
    setting.save!(validate: false)
  end

  it "starts with the hygiene policies on and auto-apply off" do
    expect(%w[dangling no_longer_flagged expire_low_confidence].map { |p| AppSettings.review_policy_enabled?(p) }).to all(be(true))
    expect(%w[auto_apply_relationships auto_apply_expired_validity].map { |p| AppSettings.review_policy_enabled?(p) }).to all(be(false))

    proposal(widget, beta, confidence: 0.95)
    summary = run

    expect(summary["policies"]["auto_apply_relationships"]).to include("disabled" => true)
    expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: beta.id)).not_to exist
  end

  describe "dangling" do
    it "dismisses rows pointing at gone or already-done things, without suppression, undoably" do
      gone = MemoryEntity.create!(name: "SynthGadget", entity_type: "Component")
      dangling = proposal(gone, beta)
      gone.destroy!
      done = proposal(widget, alpha)
      MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "depends_on")
      live = proposal(widget, beta)

      summary = run

      expect(dangling.reload).to have_attributes(status: "dismissed", resolved_by: "policy:dangling",
                                                 resolution_reason: "dangling: entity ##{gone.id} gone")
      expect(done.reload.resolution_reason).to eq("dangling: relation already exists")
      expect(live.reload.status).to eq("active")
      expect(MaintenanceReportSuppression.count).to eq(0)

      uuid = summary["policies"]["dangling"]["change_sets"].sole
      set = ChangeSet.find_by!(uuid: uuid)
      expect(set).to have_attributes(kind: "policy.dangling", actor: "policy:dangling", summary: "policy dangling: dismissed 2 rows")
      expect(dangling.change_set_id).to eq(set.id)
      expect(ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")).to be_ok
      expect([ dangling.reload.status, done.reload.status ]).to eq(%w[active active])
    end

    it "dismisses a contradiction whose side is no longer active" do
      a = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget is fast.")
      b = MemoryObservation.create!(memory_entity: beta, content: "SynthWidget is not fast.")
      pair = row("contradiction", { "observation_id_1" => a.id, "observation_id_2" => b.id })
      b.mark_obsolete!(reason: "synthetic")

      run

      expect(pair.reload).to have_attributes(status: "dismissed", resolution_reason: "dangling: observation ##{b.id} gone or no longer active")
    end

    it "is off when its toggle is off" do
      set_setting("enable_review_policy_dangling", false)
      gone = MemoryEntity.create!(name: "SynthGadget", entity_type: "Component")
      dangling = proposal(gone, beta)
      gone.destroy!

      expect(run["policies"]["dangling"]).to include("disabled" => true)
      expect(dangling.reload.status).to eq("active")
    end

    it "makes one change set per batch of 200 rows" do
      stub_const("ReviewPolicies::Base::POLICY_BATCH", 2)
      gone = MemoryEntity.create!(name: "SynthGadget", entity_type: "Component")
      3.times { proposal(gone, beta) }
      gone.destroy!

      expect(run["policies"]["dangling"]["change_sets"].size).to eq(2)
    end

    it "skips a row an operator changed between the selection and the row lock" do
      gone = MemoryEntity.create!(name: "SynthGadget", entity_type: "Component")
      dangling = proposal(gone, beta)
      gone.destroy!
      allow_any_instance_of(ReviewPolicies::Dangling).to receive(:candidates).and_wrap_original do |original|
        original.call.tap { CompactionReviewService.dismiss(dangling.row_uuid, reason: "operator first") }
      end

      expect(run["policies"]["dangling"]).to include("acted" => 0, "skipped" => 1)
      expect(dangling.reload).to have_attributes(resolution_reason: "operator first", resolved_by: "generator")
    end
  end

  it "dismisses stale_memory rows that are no longer flagged" do
    observation = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget expires.", valid_until: 1.day.from_now)
    stale = row("stale_memory", { "entity_id" => widget.id, "observation_ids" => [ observation.id ], "signal" => "valid_until_elapsed" })

    run

    expect(stale.reload).to have_attributes(status: "dismissed", resolved_by: "policy:no_longer_flagged", resolution_reason: "no longer flagged")
  end

  it "expires old low-confidence rows with a 90-day suppression" do
    weak = proposal(widget, beta, band: "low", confidence: 0.3)
    weak.update_columns(updated_at: 31.days.ago)
    fresh_weak = proposal(widget, alpha, band: "low", confidence: 0.3)

    run

    expect(weak.reload).to have_attributes(status: "expired", resolved_by: "policy:expire_low_confidence")
    expect(fresh_weak.reload.status).to eq("active")
    # One per signature the row carries (the stored one and the recomputed one).
    expect(MaintenanceReportSuppression.pluck(:source).uniq).to eq([ "expired" ])
    expect(MaintenanceReportSuppression.pluck(:expires_at)).to all(be_within(1.minute).of(90.days.from_now))
  end

  it "brings snoozed rows back when the snooze ends" do
    snoozed = proposal(widget, beta)
    CompactionReviewService.snooze(snoozed.row_uuid, days: 3)
    snoozed.reload.update_columns(expires_at: 1.minute.ago)

    run

    expect(snoozed.reload).to have_attributes(status: "active", expires_at: nil, resolved_by: nil)
    expect(MaintenanceReportSuppression.count).to eq(0)
  end

  describe "auto-apply" do
    before do
      set_setting("enable_auto_apply_relationships", true)
      set_setting("enable_auto_apply_expired_validity", true)
    end

    it "applies high-band relationship proposals at or above the threshold, never part_of" do
      strong = proposal(widget, beta, confidence: 0.95)
      weak = proposal(widget, alpha, confidence: 0.85)
      parent = proposal(alpha, beta, type: "part_of", confidence: 0.95)

      summary = run

      expect(strong.reload).to have_attributes(status: "approved", resolved_by: "policy:auto_apply_relationships")
      expect([ weak.reload.status, parent.reload.status ]).to eq(%w[active active])
      set = ChangeSet.find_by!(uuid: summary["policies"]["auto_apply_relationships"]["change_sets"].sole)
      expect(set).to have_attributes(kind: "policy.auto_apply_relationships", undo_strategy: "audit")
      expect(ChangeSetUndo.call(set.uuid, actor: "operator:steve@127.0.0.1")).to be_ok
      expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: beta.id)).not_to exist
    end

    it "uses the configured threshold" do
      set_setting("auto_apply_relationship_min_confidence", 0.8)
      weak = proposal(widget, alpha, confidence: 0.85)

      run

      expect(weak.reload.status).to eq("approved")
    end

    it "never applies destructive or choice kinds, even with tampered queries and kind lists" do
      merge = row("entity_merge", { "entity_a" => { "entity_id" => widget.id }, "entity_b" => { "entity_id" => beta.id } }, confidence: 1.0)
      sides = [ widget, beta ].map { |entity| MemoryObservation.create!(memory_entity: entity, content: "SynthWidget side #{entity.id}") }
      pair = row("contradiction", { "observation_id_1" => sides.first.id, "observation_id_2" => sides.last.id }, confidence: 1.0)
      allow_any_instance_of(ReviewPolicies::AutoApplyRelationships).to receive(:eligible)
        .and_return(MaintenanceReportRow.where(id: [ merge.id, pair.id ]))
      stub_const("ReviewRowClassifier::SAFE_BULK_KINDS", %w[relationship_proposal stale_memory entity_merge contradiction])

      summary = run

      expect(summary["policies"]["auto_apply_relationships"]).to include("refused" => 2, "acted" => 0)
      expect(MemoryEntity.exists?(beta.id)).to be(true)
      expect([ merge.reload.status, pair.reload.status ]).to eq(%w[active active])
    end

    it "applies at most 50 relationship proposals per run" do
      stub_const("ReviewPolicies::AutoApplyRelationships::PER_RUN", 1)
      proposal(widget, beta, confidence: 0.95)
      proposal(widget, alpha, confidence: 0.95)

      expect(run["policies"]["auto_apply_relationships"]["acted"]).to eq(1)
    end

    it "ends the step, not the job, when the membership lock is busy" do
      proposal(widget, beta, confidence: 0.95)
      allow(ProjectMembership).to receive(:with_membership_lock).and_raise(ProjectMembership::LockTimeout, "synthetic")

      expect(run["policies"]["auto_apply_relationships"]).to include("busy" => 1, "acted" => 0)
    end
  end

  it "writes one review_policy_run report with the counts and the apply/dismiss rates" do
    proposal(widget, beta, status: "dismissed")

    summary = run

    report = MaintenanceReport.find(summary["report_id"])
    expect(report.report_type).to eq("review_policy_run")
    expect(report.data).to include("trigger" => "spec", "policies" => include("dangling", "snooze_expiry"),
                                   "rates" => { "relationship_proposal" => { "14" => { "dismissed" => 1 } } })
    expect(report.data["backfill"]).to include("classified")
  end

  it "classifies old rows and refreshes priorities as rows age" do
    old = proposal(widget, beta)
    old.update_columns(group_key: nil, priority: 0)

    run

    expect(old.reload.group_key).to be_present
    expect(old.priority).to be > 0
  end
  describe "review round 1" do
    it "records a failing step and still runs the later policies and writes the report" do
      allow_any_instance_of(ReviewPolicies::Dangling).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "synthetic")
      snoozed = proposal(widget, beta)
      CompactionReviewService.snooze(snoozed.row_uuid, days: 3)
      snoozed.reload.update_columns(expires_at: 1.minute.ago)

      summary = run

      expect(summary["policies"]["dangling"]).to eq("error" => "ActiveRecord::StatementInvalid", "message" => "synthetic")
      expect(summary["policies"]["expire_low_confidence"]).to include("acted")
      expect(MaintenanceReport.find(summary["report_id"]).data["policies"]["dangling"]).to include("error")
    end

    it "keeps the change-set uuid of a batch a lock timeout cut short" do
      set_setting("enable_auto_apply_relationships", true)
      proposal(widget, beta, confidence: 0.95, priority: 90)
      proposal(widget, alpha, confidence: 0.95, priority: 80)
      calls = 0
      allow(CompactionReviewService).to receive(:apply).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise ProjectMembership::LockTimeout, "synthetic" if calls == 2

        original.call(*args, **kwargs)
      end

      stats = run["policies"]["auto_apply_relationships"]

      expect(stats).to include("acted" => 1, "busy" => 1)
      expect(ChangeSet.find_by!(uuid: stats["change_sets"].sole).kind).to eq("policy.auto_apply_relationships")
    end

    it "stops rescanning symmetric signatures once a pass found nothing" do
      allow(ReviewRowClassifier).to receive(:backfill!).and_call_original

      expect(run["backfill"]["symmetric_done"]).to be(true)
      run

      expect(ReviewRowClassifier).to have_received(:backfill!).with(hash_including(symmetric: true)).once
      expect(ReviewRowClassifier).to have_received(:backfill!).with(hash_including(symmetric: false)).once
    end
  end
end
