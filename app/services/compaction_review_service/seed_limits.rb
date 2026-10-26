# frozen_string_literal: true

class CompactionReviewService
  # Limits at the source (UI-5a, §2.5.4) for one seed_report call:
  # - per-run caps (ReviewRowClassifier::RUN_CAPS): at most N rows of a kind per run, counting
  #   earlier reports with the same source_ref (DreamStateCompactor flushes several times per run);
  #   the best by priority are kept;
  # - the backlog ceiling (AppSettings review_backlog_ceiling): the room left under it is filled
  #   with the best candidates; beyond it, a candidate is seeded only when its priority beats the
  #   lowest active one (a soft ceiling: nothing is evicted).
  # One COUNT and one MIN per kind per call, not per item.
  class SeedLimits
    # @param report_type [String]
    # @param source [String] the generator ("compaction_run", …)
    # @param source_ref [Object, nil] the run the reports belong to; nil = this call only
    def initialize(report_type:, source:, source_ref:)
      @report_type = report_type
      @source = source
      @source_ref = source_ref
      @skipped = { "skipped_backlog_full" => Hash.new(0), "skipped_run_cap" => Hash.new(0) }
    end

    # @param candidates [Array<Hash>] each with "kind" and "priority"
    # @return [Array<Hash>] the candidates to seed, in their original order
    def admit(candidates)
      kept = candidates.group_by { |candidate| candidate["kind"] }.flat_map do |kind, list|
        within_backlog(kind, within_run_cap(kind, list))
      end
      candidates & kept
    end

    # @return [Hash] skipped counts per kind for the report's data (empty kinds omitted)
    def stats
      @skipped.transform_values { |counts| counts.select { |_kind, count| count.positive? } }.reject { |_key, counts| counts.empty? }
    end

    private

    def within_run_cap(kind, list)
      cap = ReviewRowClassifier::RUN_CAPS[kind]
      return list unless cap

      room = [ cap - earlier_in_run(kind), 0 ].max
      ranked = list.sort_by.with_index { |candidate, index| [ -candidate["priority"], index ] }
      @skipped["skipped_run_cap"][kind] += [ ranked.size - room, 0 ].max
      ranked.first(room)
    end

    # The best candidates fill the room left under the ceiling; the rest must beat the lowest
    # active priority (the ceiling is soft: rows that beat it still come in, nothing is evicted).
    def within_backlog(kind, list)
      active = MaintenanceReportRow.by_report_type(@report_type).active.where(kind: kind)
      room = [ AppSettings.review_number(:review_backlog_ceiling) - active.count, 0 ].max
      ranked = list.sort_by.with_index { |candidate, index| [ -candidate["priority"], index ] }
      free = ranked.first(room)
      rest = ranked.drop(room)
      return free if rest.empty?

      floor = active.minimum(:priority) || free.map { |candidate| candidate["priority"] }.min || 0
      admitted, refused = rest.partition { |candidate| candidate["priority"] > floor }
      @skipped["skipped_backlog_full"][kind] += refused.size
      free + admitted
    end

    def earlier_in_run(kind)
      return 0 if @source_ref.nil?

      reports = MaintenanceReport.by_type(@report_type)
                                 .where("JSON_VALUE(data, '$.source') = ? AND JSON_VALUE(data, '$.source_ref') = ?", @source, @source_ref.to_s)
      MaintenanceReportRow.where(maintenance_report_id: reports.select(:id), kind: kind).count
    end
  end
end
