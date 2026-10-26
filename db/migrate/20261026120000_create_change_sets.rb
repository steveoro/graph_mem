# frozen_string_literal: true

# UI-4a: one row per user-visible change (a graph_write batch, a merge, a review action),
# the unit the operator can undo. Audit rows point at it through audit_logs.change_set_id.
class CreateChangeSets < ActiveRecord::Migration[8.1]
  def change
    create_table :change_sets do |t|
      t.string :uuid, limit: 36, null: false
      t.string :kind, limit: 64, null: false
      t.string :actor
      t.string :summary
      t.string :subject_type, limit: 32
      t.bigint :subject_id
      t.string :undo_strategy, limit: 16, null: false, default: "audit"
      t.string :not_undoable_reason, limit: 64
      t.json :snapshot
      t.integer :snapshot_bytes
      t.datetime :undoable_until
      t.datetime :undone_at
      t.string :undone_by
      t.references :undo_of, foreign_key: { to_table: :change_sets, on_delete: :nullify }, index: true
      t.timestamps
    end

    add_index :change_sets, :uuid, unique: true
    add_index :change_sets, :created_at
    add_index :change_sets, [ :subject_type, :subject_id ]
    add_index :change_sets, [ :actor, :created_at ]
    add_index :change_sets, [ :kind, :created_at ]
  end
end
