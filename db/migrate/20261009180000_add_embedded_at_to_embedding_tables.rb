# frozen_string_literal: true

# Tracks "is this row's vector real?" in its own column. The VECTOR index
# requires NOT NULL and column DEFAULTs are lost in structure dumps, so
# neither a nullable column nor a DEFAULT()-based predicate works — a
# dedicated timestamp does (NULL = placeholder zero-vector awaiting
# backfill, timestamp = real vector written by EmbeddingService#store_vector).
class AddEmbeddedAtToEmbeddingTables < ActiveRecord::Migration[8.1]
  def up
    add_column :memory_entities, :embedded_at, :datetime, precision: 6
    add_index :memory_entities, :embedded_at, name: "idx_memory_entities_embedded_at"
    add_column :memory_observations, :embedded_at, :datetime, precision: 6
    add_index :memory_observations, :embedded_at, name: "idx_memory_observations_embedded_at"

    # Mark existing real vectors: rows whose embedding differs from the
    # all-zero placeholder the BEFORE INSERT trigger writes. The schema is
    # fixed at VECTOR(768), so the literal repeats '0,' 767 times.
    zero_vector = "VEC_FromText(CONCAT('[', REPEAT('0,', 767), '0]'))"
    execute <<~SQL
      UPDATE memory_entities
         SET embedded_at = updated_at
       WHERE embedded_at IS NULL
         AND embedding <> #{zero_vector}
    SQL
    execute <<~SQL
      UPDATE memory_observations
         SET embedded_at = updated_at
       WHERE embedded_at IS NULL
         AND embedding <> #{zero_vector}
    SQL
  end

  def down
    remove_index :memory_observations, name: "idx_memory_observations_embedded_at"
    remove_column :memory_observations, :embedded_at
    remove_index :memory_entities, name: "idx_memory_entities_embedded_at"
    remove_column :memory_entities, :embedded_at
  end
end
