# frozen_string_literal: true

# Manages VECTOR index DDL for embedding columns (MariaDB 11.7+).
class EmbeddingIndexManager
  class Error < StandardError; end
  class PrecheckError < Error; end

  class << self
    def add_indexes!
      new.add_indexes!
    end

    def drop_indexes!
      new.drop_indexes!
    end
  end

  def add_indexes!
    conn = ActiveRecord::Base.connection
    dims = EmbeddingConfig.resolved_config[:dims]

    unless conn.column_exists?(:memory_entities, :embedding)
      raise PrecheckError, "embedding columns don't exist. Run migrations first."
    end

    entity_nulls = MemoryEntity.where(embedding: nil).count
    obs_nulls = MemoryObservation.where(embedding: nil).count

    if entity_nulls.positive? || obs_nulls.positive?
      raise PrecheckError,
            "#{entity_nulls} entities and #{obs_nulls} observations still have NULL embeddings. " \
            "Run backfill first."
    end

    zero_vec_default = zero_vector_sql(dims)

    conn.execute "ALTER TABLE memory_entities MODIFY embedding VECTOR(#{dims}) NOT NULL DEFAULT #{zero_vec_default}"
    conn.execute "ALTER TABLE memory_observations MODIFY embedding VECTOR(#{dims}) NOT NULL DEFAULT #{zero_vec_default}"

    conn.execute <<~SQL
      ALTER TABLE memory_entities
        ADD VECTOR INDEX idx_memory_entities_embedding (embedding)
        DISTANCE=cosine
    SQL

    conn.execute <<~SQL
      ALTER TABLE memory_observations
        ADD VECTOR INDEX idx_memory_observations_embedding (embedding)
        DISTANCE=cosine
    SQL

    EmbeddingService.reset_vector_cache!
    EmbeddingService.reset_instance!

    {
      success: true,
      message: "VECTOR INDEX active — ANN search enabled.",
      indexes: EmbeddingIndexStatus.indexes
    }
  end

  def drop_indexes!
    conn = ActiveRecord::Base.connection
    dims = EmbeddingConfig.resolved_config[:dims]

    %w[memory_entities memory_observations].each do |table|
      index_name = "idx_#{table}_embedding"
      result = conn.execute("SHOW INDEX FROM #{table} WHERE Key_name = '#{index_name}'")
      conn.execute("ALTER TABLE #{table} DROP INDEX #{index_name}") if result.count.positive?

      conn.execute("ALTER TABLE #{table} MODIFY embedding VECTOR(#{dims}) DEFAULT NULL")
    end

    EmbeddingService.reset_vector_cache!
    EmbeddingService.reset_instance!

    {
      success: true,
      message: "VECTOR INDEX removed. Brute-force search still works.",
      indexes: EmbeddingIndexStatus.indexes
    }
  end

  private

  def zero_vector_sql(dims)
    repeats = dims - 1
    "(VEC_FromText(CONCAT('[', REPEAT('0,', #{repeats}), '0]')))"
  end
end
