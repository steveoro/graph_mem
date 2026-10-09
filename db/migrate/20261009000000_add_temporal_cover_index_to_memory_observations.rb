# frozen_string_literal: true

# Covering index for the temporal recall channel: TemporalSearchStrategy
# groups active observations by entity and orders by in-window count, so a
# (status, memory_entity_id, valid_from, valid_until, created_at) index makes
# the whole query index-only instead of scanning dated rows.
class AddTemporalCoverIndexToMemoryObservations < ActiveRecord::Migration[8.1]
  def change
    add_index :memory_observations,
              %i[status memory_entity_id valid_from valid_until created_at],
              name: :index_memory_observations_temporal_cover
  end
end
