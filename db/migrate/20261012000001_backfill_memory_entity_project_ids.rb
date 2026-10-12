# frozen_string_literal: true

# Data half of project-scoped names: stamps project_id for every entity
# already sitting under a Project root. Idempotent — a re-run changes 0
# rows. See AddProjectScopeToMemoryEntities for the schema half.
class BackfillMemoryEntityProjectIds < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Backfilling memory_entities.project_id" do
      begin
        ProjectIdBackfill.new(out: ->(line) { say line }).run(dry_run: false)
      rescue ActiveRecord::RecordNotUnique => e
        # A stamped-but-unrooted row sharing a global name aborts the apply —
        # the transaction rolls back, so re-running after deduping is safe.
        raise ActiveRecord::RecordNotUnique, ProjectIdBackfill.conflict_hint(e)
      end
    end
  end

  def down
    # Reversible: NULL the stamp out again. The schema migration's own `down`
    # drops the column anyway; clearing it here keeps this step honest when
    # rolled back alone.
    execute "UPDATE memory_entities SET project_id = NULL" if column_exists?(:memory_entities, :project_id)
  end
end
