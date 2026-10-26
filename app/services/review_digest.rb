# frozen_string_literal: true

# The Review page's groups (UI-5b C2): active rows of compaction and scan review grouped by
# group_key and ranked by priority alone (Decision 13: no root-first key here). SQL only, with a
# query count that doesn't grow with the queue.
#
#   digest = ReviewDigest.new
#   digest.attention   # => up to 10 Group structs at or above the attention threshold
#   digest.below       # => { groups: 38, rows: 214 }
class ReviewDigest
  REPORT_TYPES = %w[compaction_review scan_review].freeze
  # Rows classified before UI-5a have no group_key: each is its own group.
  GROUP_SQL = "COALESCE(group_key, CONCAT(kind, '|row:', row_uuid))"
  HIGH_CONFIDENCE = 0.8
  DIGEST_SIZE = 10

  Group = Struct.new(:key, :kind, :anchor_id, :anchor_name, :count, :high_confidence, :max_confidence,
                     :oldest_at, :max_priority, :report_type, keyword_init: true)

  # @return [Integer] groups at or above the attention threshold (the nav badge)
  def self.attention_group_count
    new.attention_count
  end

  # @param threshold [Integer] review_attention_threshold by default
  # @param scope [ActiveRecord::Relation] rows to group (active compaction + scan review by default)
  def initialize(threshold: AppSettings.review_number(:review_attention_threshold), scope: nil)
    @threshold = threshold
    @scope = scope || MaintenanceReportRow.active.where(report_type: REPORT_TYPES)
  end

  attr_reader :threshold

  # @return [Array<Group>] the top groups at or above the threshold
  def attention
    groups(@scope, having: [ "MAX(priority) >= ?", @threshold ], limit: DIGEST_SIZE)
  end

  # @return [Integer]
  def attention_count
    @scope.group(Arel.sql(GROUP_SQL)).having("MAX(priority) >= ?", @threshold).count.size
  end

  # @return [Hash] `{ groups:, rows: }` below the threshold
  def below
    inner = @scope.select(Arel.sql("COUNT(*) AS n")).group(Arel.sql(GROUP_SQL)).having("MAX(priority) < ?", @threshold)
    groups, rows = MaintenanceReportRow.from(inner, :below).pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(n), 0)"))
    { groups: groups.to_i, rows: rows.to_i }
  end

  # One page of groups for the grouped lists (By kind, By project, Errors, Scan review).
  # @return [Array<Group>]
  def page(scope, page:, per: 25)
    groups(scope, limit: per, offset: ([ page.to_i, 1 ].max - 1) * per)
  end

  # @return [Integer] rows the policies resolved over the last 7 days
  def policies_resolved_this_week
    MaintenanceReport.by_type("review_policy_run").where(created_at: 7.days.ago..).pluck(:data).sum do |data|
      Hash(data["policies"]).values.sum { |stats| stats.is_a?(Hash) ? stats["acted"].to_i : 0 }
    end
  end

  # @return [Time, nil] the next scheduled compaction run (config/recurring.yml)
  def next_compaction_at
    entry = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
                .fetch(Rails.env, {}).values.find { |job| job.is_a?(Hash) && job["class"] == "DreamStateCompactionJob" }
    entry && Fugit.parse(entry["schedule"])&.next_time&.to_t
  rescue StandardError
    nil
  end

  private

  COLUMNS = [
    GROUP_SQL, "MIN(kind)", "MAX(anchor_entity_id)", "COUNT(*)", "SUM(confidence >= #{HIGH_CONFIDENCE})",
    "MAX(confidence)", "MIN(created_at)", "MAX(priority)", "MIN(report_type)"
  ].map { |sql| Arel.sql(sql) }.freeze

  def groups(scope, having: nil, limit:, offset: 0)
    relation = scope.group(Arel.sql(GROUP_SQL)).order(Arel.sql("MAX(priority) DESC, MIN(id) ASC")).limit(limit).offset(offset)
    relation = relation.having(*having) if having
    rows = relation.pluck(*COLUMNS)
    names = MemoryEntity.where(id: rows.filter_map { |row| row[2] }).pluck(:id, :name).to_h
    rows.map do |key, kind, anchor, count, high, max_confidence, oldest, priority, report_type|
      Group.new(key: key, kind: kind, anchor_id: anchor, anchor_name: names[anchor], count: count, high_confidence: high.to_i,
                max_confidence: max_confidence&.to_f, oldest_at: oldest, max_priority: priority, report_type: report_type)
    end
  end
end
