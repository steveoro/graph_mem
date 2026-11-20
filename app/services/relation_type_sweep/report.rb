# frozen_string_literal: true

class RelationTypeSweep
  # The sweep's run report: one MaintenanceReport (`report_type: "relation_type_sweep"`, see
  # MaintenanceReport::INTERNAL_REPORT_TYPES) per run, updated after each batch, so a dream-state
  # run that spreads its batches over many jobs still ends with one report. Its data:
  #
  #   { "source" => "rake", "source_ref" => nil, "actor" => "rake:canonicalize_relations",
  #     "started_at" => "…", "finished_at" => "…",
  #     "counts" => { "scanned" => 812, "unchanged" => 790, "case_only" => 2, "retyped" => 15, "merged" => 3,
  #                   "queued" => 2, "already_queued" => 0, "skipped_part_of" => 0, "error" => 0 },
  #     "changes" => [{ "relation_id" => 41, "action" => "merged", "old_type" => "has-many", "new_type" => "has_many",
  #                     "from_entity_id" => 7, "to_entity_id" => 9, "merged_into_id" => 40 }, …],
  #     "changes_omitted" => 0, "change_sets" => ["<uuid>", …] }
  #
  # The list holds every relation that wasn't unchanged, up to MAX_REPORTED_CHANGES (the rest is
  # counted in "changes_omitted"); the counts always cover the whole run. A dry run writes nothing
  # and keeps the same shape in memory.
  module Report
    # @return [Integer, nil] the report's id (nil in a dry run, or before the first write)
    attr_reader :report_id

    # Ends the run: stamps the report finished (creating it when the run had nothing to scan).
    #
    # @return [Hash] see #summary
    def finish!
      unless @dry_run
        update_report! { |data| data["finished_at"] = Time.current.iso8601 }
        UnmappedRelationTypes.expire_cached_count! # the stored types changed
      end
      summary
    end

    # @return [Hash] `{ dry_run:, counts:, changes:, changes_omitted:, report_id: }`: the whole run
    #   for a report (every batch appended to it), this sweep's batches for a dry run
    def summary
      if @dry_run || @report.nil?
        return { dry_run: @dry_run, counts: empty_counts.merge(@counts), changes: @changes, changes_omitted: @omitted,
                 report_id: nil }
      end

      data = @report.data
      { dry_run: false, counts: data["counts"], changes: data["changes"], changes_omitted: data["changes_omitted"],
        report_id: @report.id }
    end

    private

    def empty_counts
      { "scanned" => 0 }.merge(RelationTypeSweep::OUTCOMES.index_with(0))
    end

    # Adds a batch to this sweep's totals and, unless dry, to the report.
    def remember(counts, changes)
      counts.each { |key, value| @counts[key] += value }
      listed = changes.reject { |change| change["action"] == "unchanged" }
      room = [ RelationTypeSweep::MAX_REPORTED_CHANGES - @changes.size, 0 ].max
      @changes.concat(listed.first(room))
      @omitted += [ listed.size - room, 0 ].max
      record_report!(counts, listed) unless @dry_run
    end

    def record_report!(counts, listed)
      update_report! do |data|
        counts.each { |key, value| data["counts"][key] = data["counts"].fetch(key, 0) + value }
        room = [ RelationTypeSweep::MAX_REPORTED_CHANGES - data["changes"].size, 0 ].max
        data["changes"].concat(listed.first(room))
        data["changes_omitted"] += [ listed.size - room, 0 ].max
        data["change_sets"].concat(@new_change_sets.to_a)
        @new_change_sets = []
      end
    end

    # Gives the batch's change set its summary and remembers its uuid for the report.
    def note_change_set(context, changes)
      return unless context&.id

      done = changes.group_by { |change| change["action"] }.transform_values(&:size)
      parts = { "retyped" => "retyped", "merged" => "merged", "case_only" => "case fixed" }
              .filter_map { |action, label| "#{done[action]} #{label}" if done[action] }
      ChangeSet.where(id: context.id).update_all(summary: "relation types canonicalized: #{parts.join(', ').presence || 'nothing'}")
      (@new_change_sets ||= []) << context.uuid
    end

    def update_report!
      @report ||= MaintenanceReport.find_by(id: @report_id, report_type: RelationTypeSweep::REPORT_TYPE) if @report_id
      @report ||= MaintenanceReport.create!(report_type: RelationTypeSweep::REPORT_TYPE, data: initial_data)
      @report_id = @report.id
      data = @report.data.deep_dup
      yield data
      @report.update!(data: data)
    end

    def initial_data
      { "source" => @source, "source_ref" => @source_ref, "actor" => @actor, "started_at" => Time.current.iso8601,
        "finished_at" => nil, "counts" => empty_counts, "changes" => [], "changes_omitted" => 0, "change_sets" => [] }
    end
  end
end
