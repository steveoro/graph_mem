# frozen_string_literal: true

# VECTOR INDEX requires NOT NULL columns, but we keep embedding columns nullable
# so the app works before embeddings are backfilled.
#
# Vector search works without the index via brute-force VEC_DISTANCE_COSINE,
# which is plenty fast for < 100K rows.
#
# After backfilling all embeddings, run:
#   bundle exec rake embeddings:add_indexes
# to convert columns to NOT NULL and add HNSW VECTOR INDEX for ANN search.
class AddVectorIndexes < ActiveRecord::Migration[8.0]
  def up
    if column_exists?(:memory_entities, :embedding)
      say "VECTOR columns present. Skipping VECTOR INDEX creation (requires NOT NULL)."
      say "After backfilling embeddings, run: bundle exec rake embeddings:add_indexes"
    else
      say "No embedding columns found — nothing to index."
    end
  end

  def down
    if index_exists_raw?("memory_entities", "idx_memory_entities_embedding")
      execute "ALTER TABLE memory_entities DROP INDEX idx_memory_entities_embedding"
    end

    if index_exists_raw?("memory_observations", "idx_memory_observations_embedding")
      execute "ALTER TABLE memory_observations DROP INDEX idx_memory_observations_embedding"
    end
  end

  private

  def index_exists_raw?(table, index_name)
    result = execute("SHOW INDEX FROM #{table} WHERE Key_name = '#{index_name}'")
    result.count > 0
  rescue StandardError
    false
  end
end
