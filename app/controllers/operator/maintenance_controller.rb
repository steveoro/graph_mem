# frozen_string_literal: true

module Operator
  class MaintenanceController < ApplicationController
    def start_compaction
      unless AppSettings.dream_state_compactor_enabled?
        redirect_to root_path, alert: t("operator.maintenance.compactor_disabled")
        return
      end

      run = CompactionRunner.start_or_resume!
      redirect_to root_path, notice: "Dream-state compaction started (run ##{run.id})."
    end

    def pause_compaction
      run = CompactionRun.current
      if run&.running?
        run.request_pause!
        redirect_to root_path, notice: "Pause requested for dream-state compaction (run ##{run.id})."
      else
        redirect_to root_path, alert: "No running compaction to pause."
      end
    end

    def run_garbage_collection
      unless AppSettings.garbage_collector_enabled?
        redirect_to root_path, alert: t("operator.maintenance.gc_disabled")
        return
      end

      result = GarbageCollectionRunner.call
      counts = result[:reports].map { |r| "#{r[:report_type]}: #{r[:count]}" }.join(", ")
      redirect_to root_path,
                  notice: "Garbage collection completed. #{counts}. Pruned #{result[:audit_logs_pruned]} audit logs."
    end

    def repair_relations
      result = RelationIntegrityRepairer.call(dry_run: false)
      message = relation_repair_notice(result)
      redirect_to root_path, notice: message
    end

    private

    def relation_repair_notice(result)
      parts = [
        "Relation repair completed.",
        "Deleted #{result.deleted_count} relation(s).",
        "Same-direction duplicates: #{result.same_direction_duplicates.size}.",
        "Reverse pairs: #{result.reverse_pairs.size}.",
        "Merge collisions: #{result.merge_collisions.size}."
      ]
      parts.join(" ")
    end
  end
end
