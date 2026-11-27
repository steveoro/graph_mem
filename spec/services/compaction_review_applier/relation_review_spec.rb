# frozen_string_literal: true

require "rails_helper"

# Dream State R1c: a relation_review row is informational. Apply answers a validation error and
# writes nothing; no bulk, group or policy apply touches it; Dangling dismisses it once its relation
# or its fact is gone.
RSpec.describe CompactionReviewApplier::RelationReview do
  let(:operator) { "operator:synth@127.0.0.1" }
  let!(:app) { fs_project!("SynthApp") }
  let!(:library) { MemoryEntity.create!(name: "SynthLib", entity_type: "Gem") }
  let!(:uses) { MemoryRelation.create!(from_entity: app, to_entity: library, relation_type: "depends_on") }
  let!(:fact) { fs_observe!(app, "SynthApp replaced SynthLib with SynthParser.") }
  let!(:row) do
    relation = RemovalEvidence.edges(after_id: 0, limit: 10).sole
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: [ described_class.item(relation, fact) ]).sole
  end

  it "answers a validation error on apply and writes nothing: no lock, no change set, the row stays active" do
    change_sets = ChangeSet.count
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Current.set(actor: operator) { CompactionReviewService.apply(row.row_uuid) }
    end

    expect(result).to eq(success: false, error: described_class::MESSAGE, validation: true, next_move: described_class::NEXT_MOVE)
    expect(described_class::MESSAGE).to eq("ending a relation arrives with the relation lifecycle; remove the relation by hand if it is wrong")
    expect(queries.grep(/GET_LOCK/)).to be_empty
    expect(ChangeSet.count).to eq(change_sets)
    expect(row.reload).to have_attributes(status: "active", resolution_reason: nil)
    expect(MemoryRelation.exists?(uses.id)).to be(true)
  end

  it "previews as not applicable, with the same message" do
    expect(CompactionReviewApplier.preview(row)).to include(ok: false, effects: [], warnings: [ described_class::MESSAGE ])
  end

  it "can be dismissed and snoozed like any row" do
    expect(CompactionReviewService.snooze(row.row_uuid)).to include(success: true)
    expect(row.reload.status).to eq("ignored")
    expect(CompactionReviewService.restore(row.row_uuid)).to include(success: true)
    expect(CompactionReviewService.dismiss(row.row_uuid, reason: "still used")).to include(success: true)
    expect(CompactionReviewService.suppressed?("relation_review", row.payload)).to be(true)
  end

  it "refuses an edit" do
    expect(CompactionReviewService.edit_item(row.row_uuid, { relation_id: 1 }))
      .to eq(success: false, error: "Validation failed: Relation review rows can't be edited; dismiss or snooze them")
  end

  describe "never applied in bulk" do
    it "is refused by an auto-apply policy, even when its candidate query returns it" do
      policy = ReviewPolicies::AutoApplyRelationships.new
      allow(policy).to receive_messages(enabled?: true, eligible: MaintenanceReportRow.where(id: row.id))

      expect(policy.call).to include("acted" => 0, "refused" => 1)
      expect(row.reload.status).to eq("active")
    end

    it "is excluded from group apply and from bulk apply" do
      preview = ReviewGroupActions.preview(group_key: row.group_key, op: "apply")

      expect(preview[:excluded]).to contain_exactly(include(row_uuid: row.row_uuid, reason: "informational: dismiss or snooze it"))
      expect(ReviewGroupActions.apply(group_key: row.group_key, row_uuids: [ row.row_uuid ], token: preview[:token]))
        .to include(success: false, status: :unprocessable)
      expect(CompactionReviewService.bulk_apply([ row.row_uuid ])[:message]).to include("1 skipped (not bulk-applicable")
      expect(row.reload.status).to eq("active")
    end
  end

  describe "Dangling policy" do
    def dangling = ReviewPolicies::DanglingCheck.reason(row.reload)

    it "keeps a row whose relation and fact are there" do
      expect(dangling).to be_nil
    end

    it "dismisses a row whose fact is no longer active" do
      fact.mark_obsolete!(reason: "synthetic retire")

      expect(dangling).to eq("observation ##{fact.id} gone or no longer active")
    end

    it "dismisses a row whose relation is gone" do
      uses.destroy!
      expect(dangling).to eq("relation ##{uses.id} gone")

      ReviewPolicies::Dangling.new.call
      expect(row.reload).to have_attributes(status: "dismissed", resolution_reason: "dangling: relation ##{uses.id} gone")
    end
  end
end
