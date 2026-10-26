# frozen_string_literal: true

# Runs the review policies (UI-5a, `ui-dashboard-plan.md` §2.5.3) and writes one
# `review_policy_run` MaintenanceReport per run. Order: classify rows seeded before UI-5a (bounded),
# refresh the priority of active rows (age raises it), then the policies below. Each policy reads
# its toggle uncached at the start, acts in batches of 200 rows (one undoable change set each,
# actor `policy:<name>`) and never touches destructive or choice kinds.
#
#   ReviewPolicyRunner.call(trigger: "nightly")
#   # => { report_id: 12, policies: { "dangling" => { "acted" => 3, ... }, ... }, ... }
class ReviewPolicyRunner
  POLICIES = [
    ReviewPolicies::SnoozeExpiry, ReviewPolicies::Dangling, ReviewPolicies::NoLongerFlagged,
    ReviewPolicies::ExpireLowConfidence, ReviewPolicies::AutoApplyExpiredValidity, ReviewPolicies::AutoApplyRelationships
  ].freeze
  BACKFILL_PER_RUN = 5_000
  REFRESH_BATCH = 1_000
  # Apply/dismiss rates for tuning RelationshipDiscoveryStrategy::MIN_QUEUE_SCORE come from rows
  # resolved in this window.
  RATES_WINDOW = 30.days

  # @param trigger [String] what started the run ("nightly", "compaction", "stale_scan", "project_scan", …)
  # @return [Hash] the run summary (also stored in the report's data)
  def self.call(trigger:)
    new(trigger).call
  end

  def initialize(trigger)
    @trigger = trigger.to_s
  end

  def call
    summary = {
      "trigger" => @trigger,
      "backfill" => ReviewRowClassifier.backfill!(limit: BACKFILL_PER_RUN).stringify_keys,
      "priorities_refreshed" => refresh_priorities,
      "policies" => POLICIES.to_h { |policy| [ policy.policy_name, policy.new.call ] },
      "rates" => rates
    }
    report = MaintenanceReport.create!(report_type: "review_policy_run", data: summary)
    summary.merge("report_id" => report.id)
  end

  private

  # Priority is derived data: written with update_columns, no change set.
  def refresh_priorities
    classifier = ReviewRowClassifier.new
    refreshed = 0
    MaintenanceReportRow.active.find_in_batches(batch_size: REFRESH_BATCH) do |rows|
      rows.each do |row|
        priority = classifier.classify(row)[:priority]
        next if priority == row.priority

        row.update_columns(priority: priority)
        refreshed += 1
      end
    end
    refreshed
  end

  # { kind => { score => { status => count } } } for rows resolved in RATES_WINDOW.
  def rates
    score = "COALESCE(JSON_VALUE(payload, '$.score'), 'none')"
    MaintenanceReportRow.resolved.where(updated_at: RATES_WINDOW.ago..)
                        .group(:kind, Arel.sql(score), :status).count
                        .each_with_object({}) do |((kind, bucket, status), count), rates|
                          ((rates[kind] ||= {})[bucket.to_s] ||= {})[status] = count
                        end
  end
end
