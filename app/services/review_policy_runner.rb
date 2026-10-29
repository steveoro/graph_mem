# frozen_string_literal: true

# Runs the review policies (UI-5a, the UI plan §2.5.3) and writes one
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
    ReviewPolicies::ExpireLowConfidence, ReviewPolicies::AutoApplyExpiredValidity, ReviewPolicies::AutoApplyRelationships,
    ReviewPolicies::AutoApplyFactSupersede
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

  # Each step is rescued on its own: a failing step records its error and the run carries on, so
  # the later policies still run and the report is always written.
  def call
    summary = {
      "trigger" => @trigger,
      "backfill" => step("backfill") { backfill },
      "priorities_refreshed" => step("priorities") { refresh_priorities },
      "policies" => POLICIES.to_h { |policy| [ policy.policy_name, step(policy.policy_name) { policy.new.call } ] },
      "rates" => step("rates") { rates }
    }
    report = MaintenanceReport.create!(report_type: "review_policy_run", data: summary)
    summary.merge("report_id" => report.id)
  end

  private

  def step(name)
    yield
  rescue StandardError => e
    Rails.logger.error "[ReviewPolicyRunner] #{name} failed: #{e.class}: #{e.message}"
    { "error" => e.class.name, "message" => e.message.to_s.truncate(200) }
  end

  # The symmetric-signature steps stop once a full pass found nothing (flag carried in the reports).
  def backfill
    done = symmetric_done?
    counts = ReviewRowClassifier.backfill!(limit: BACKFILL_PER_RUN, symmetric: !done).stringify_keys
    counts.merge("symmetric_done" => done || counts.values_at("rewritten", "duplicates", "twins").sum.zero?)
  end

  def symmetric_done?
    MaintenanceReport.by_type("review_policy_run").recent.limit(1)
                     .pick(Arel.sql("JSON_VALUE(data, '$.backfill.symmetric_done')")).to_s.in?(%w[1 true]) # MariaDB answers "1"
  end

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
