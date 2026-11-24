# frozen_string_literal: true

# Data only (no schema change): re-runs the project_id backfill once, so membership drift left by
# the part_of writers fixed in this release (entity delete, merge, the operator's relation repair,
# scans and imports stamping entities without a part_of) is repaired on upgrade. A stamp with no
# path is repaired toward the stamp when its part_of chain is stamped consistently (the chain's top
# gets a part_of to that project's root, in one `maintenance.membership_repair` change set), else
# cleared (ProjectIdBackfill). Logs the drift counts before and after (ProjectIdBackfill.drift).
#
# Never fails the deploy: production runs db:prepare at container boot, and a failed migration
# would keep the app down. On a name collision (or a busy membership lock) it logs why, leaves the
# data unchanged and completes; fix the name and run `bin/rails graph_mem:backfill_project_ids`.
# Uses ProjectIdBackfill like BackfillMemoryEntityProjectIds, and nothing else of the app.
class RepairMemoryEntityProjectIds < ActiveRecord::Migration[8.1]
  def up
    log_drift("before")
    say_with_time "Repairing memory_entities.project_id from the part_of tree" do
      ProjectIdBackfill.new(out: ->(line) { say line, true }).run(dry_run: false)
    rescue ActiveRecord::RecordNotUnique => e
      # The transactional apply rolled back: nothing changed.
      skipped("a name collision: #{ProjectIdBackfill.conflict_hint(e)}")
    rescue ProjectMembership::LockTimeout, ActiveRecord::LockWaitTimeout => e
      skipped("the membership lock stayed busy: #{e.message}")
    end
    log_drift("after")
  end

  def down
    # Nothing to undo: the repair only recomputed project_id from the part_of edges, which it never
    # changed; the stamps it fixed were wrong.
  end

  private

  def log_drift(moment)
    line = "membership drift #{moment}: #{ProjectIdBackfill.drift.summary}"
    say line
    Rails.logger.info("[RepairMemoryEntityProjectIds] #{line}")
  end

  def skipped(reason)
    message = "project_id repair skipped, data unchanged, because of #{reason}. " \
              "Fix it, then run bin/rails graph_mem:backfill_project_ids"
    say message, true
    Rails.logger.warn("[RepairMemoryEntityProjectIds] #{message}")
  end
end
