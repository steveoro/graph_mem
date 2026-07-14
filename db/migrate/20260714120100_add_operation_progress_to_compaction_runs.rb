# frozen_string_literal: true

class AddOperationProgressToCompactionRuns < ActiveRecord::Migration[8.0]
  def change
    add_reference :compaction_runs, :operation_progress, foreign_key: true
  end
end
