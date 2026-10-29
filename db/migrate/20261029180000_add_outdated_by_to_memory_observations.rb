# frozen_string_literal: true

# Fact supersede (1.64.0): the source fact that outdated an observation (retired or superseded
# it), so "what did fact #N retire?" is one query and the panel can link "Outdated by". Nullable;
# deleting the fact clears the link (ON DELETE SET NULL), as superseded_by_id does.
class AddOutdatedByToMemoryObservations < ActiveRecord::Migration[8.1]
  def change
    add_reference :memory_observations, :outdated_by, null: true, index: true,
                                                      foreign_key: { to_table: :memory_observations, on_delete: :nullify }
  end
end
