# frozen_string_literal: true

class DreamStateCompactor
  # Phase `relation_types` (R1a), the first of every run: RelationTypeSweep over relation ids, one
  # batch of RelationTypeSweep::BATCH_SIZE relations per job. Its cursor is a relation id, kept in
  # the run's stats ("relation_cursor_id"), so `cursor_entity_id` (an entity, shown on the dashboard
  # and by dream_state_status) stays empty during the phase. The run's one sweep report is appended
  # to by every batch ("relation_types_report_id"). Pause is checked after each batch, like after
  # each entity in the other phases. Writes are attributed to "compaction:<run id>".
  module RelationTypesPhase
    PHASE = "relation_types"
    # Run stats this phase adds up, from the sweep's per-batch counts.
    STATS = {
      "relation_types_fixed" => %w[case_only retyped],
      "relation_types_merged" => %w[merged],
      "relation_retypes_queued" => %w[queued]
    }.freeze

    private

    # @return [Symbol] :continued, :paused or :completed (as #process_batch!)
    def process_relation_types_batch!
      stats = @run.stats || {}
      sweep = RelationTypeSweep.new(actor: "compaction:#{@run.id}", source: "dream_state", source_ref: @run.id,
                                    report_id: stats["relation_types_report_id"])
      batch = sweep.process_batch(after_id: stats["relation_cursor_id"].to_i)
      record_relation_batch!(stats, sweep, batch)
      broadcast_progress(PHASE, step: batch.scanned, message: "Checked relation types up to ##{batch.last_id}") if batch.scanned.positive?

      return finish_relation_types!(sweep) if batch.scanned < sweep.batch_size

      if @run.reload.pause_requested?
        @run.pause!
        broadcast_operation(message: "Compaction paused")
        return :paused
      end
      :continued
    end

    def record_relation_batch!(stats, sweep, batch)
      updates = STATS.to_h do |stat, outcomes|
        [ stat, stats[stat].to_i + outcomes.sum { |outcome| batch.counts[outcome].to_i } ]
      end
      @run.merge_stats!(updates.merge("relation_cursor_id" => batch.last_id,
                                      "relations_processed" => stats["relations_processed"].to_i + batch.scanned,
                                      "relation_types_report_id" => sweep.report_id))
    end

    def finish_relation_types!(sweep)
      sweep.finish!
      @run.merge_stats!("relation_types_report_id" => sweep.report_id)
      advance_phase!(PHASE)
      broadcast_operation(message: @run.completed? ? "Compaction completed" : "Completed #{PHASE} phase")
      @run.reload.completed? ? :completed : :continued
    end
  end
end
