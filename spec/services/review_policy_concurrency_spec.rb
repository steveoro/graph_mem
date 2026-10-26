# frozen_string_literal: true

require "rails_helper"

# UI-5a B1: a policy batch and an operator apply on the same row serialize on the row lock; one
# wins, the other skips. Never a 500, a partial state or a leftover lock.
RSpec.describe "Review policy concurrency" do
  # Real commits from two connections: no wrapping transaction, explicit cleanup.
  self.use_transactional_tests = false

  let(:tag) { SecureRandom.hex(4) }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget #{tag}", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "SynthWidget beta #{tag}", entity_type: "Component") }
  let!(:row) do
    MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: "race-#{tag}", kind: "relationship_proposal",
                                 status: "active", signature: "relationship_proposal|#{widget.id}|#{beta.id}|depends_on",
                                 group_key: "relationship_proposal|#{tag}", confidence: 0.3,
                                 payload: { "from_entity_id" => widget.id, "to_entity_id" => beta.id, "relation_type" => "depends_on",
                                            "confidence_band" => "low" }).tap { |r| r.update_columns(updated_at: 40.days.ago) }
  end

  around do |example|
    started_at = Time.current
    example.run
  ensure
    MemoryRelation.where(created_at: started_at..).delete_all
    MaintenanceReportSuppression.where(created_at: started_at..).delete_all
    MaintenanceReportRow.where("row_uuid LIKE ?", "race-%").delete_all
    MemoryEntity.where("name LIKE ?", "SynthWidget %").delete_all
    AuditLog.where(created_at: started_at..).delete_all
    ChangeSet.where(created_at: started_at..).delete_all
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |t| t.report_on_exception = false }
  end

  def expire_policy = ReviewPolicies::ExpireLowConfidence.new.call

  it "an operator apply holding the row wins; the policy skips the row" do
    locked = Queue.new
    release = Queue.new
    allow(CompactionReviewApplier).to receive(:apply).and_wrap_original do |original, *args|
      locked << true
      release.pop
      original.call(*args)
    end

    operator = in_thread { CompactionReviewService.apply(row.row_uuid) }
    locked.pop
    policy = in_thread { expire_policy }
    expect(policy.join(0.5)).to be_nil # waiting on the row lock
    release << true

    expect(operator.value).to include(success: true)
    expect(policy.value).to include("acted" => 0, "skipped" => 1)
    expect(row.reload).to have_attributes(status: "approved", resolved_by: "generator")
    expect(MaintenanceReportSuppression.where(signature: row.signature)).not_to exist
    expect(membership_lock_free?).to be(true)
  end

  it "a policy holding the row wins; the operator apply answers not actionable" do
    locked = Queue.new
    release = Queue.new
    allow_any_instance_of(ReviewPolicies::ExpireLowConfidence).to receive(:act).and_wrap_original do |original, *args|
      locked << true
      release.pop
      original.call(*args)
    end

    policy = in_thread { expire_policy }
    locked.pop
    operator = in_thread { CompactionReviewService.apply(row.row_uuid) }
    expect(operator.join(0.5)).to be_nil
    release << true

    expect(policy.value).to include("acted" => 1)
    expect(operator.value).to include(success: false, error: "Suggestion is not actionable (status: expired)")
    expect(row.reload).to have_attributes(status: "expired", resolved_by: "policy:expire_low_confidence")
    expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: beta.id)).not_to exist
    expect(membership_lock_free?).to be(true)
  end
end
