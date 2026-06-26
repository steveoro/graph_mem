# frozen_string_literal: true

# Reports whether VECTOR ANN indexes exist on embedding columns.
module EmbeddingIndexStatus
  INDEX_NAMES = {
    memory_entities: "idx_memory_entities_embedding",
    memory_observations: "idx_memory_observations_embedding"
  }.freeze

  module_function

  def indexes
    return default_indexes unless EmbeddingService.vector_enabled?

    {
      memory_entities: index_exists?("memory_entities", INDEX_NAMES[:memory_entities]),
      memory_observations: index_exists?("memory_observations", INDEX_NAMES[:memory_observations])
    }
  end

  def index_exists?(table, index_name)
    conn = ActiveRecord::Base.connection
    return false unless conn.table_exists?(table)

    result = conn.execute("SHOW INDEX FROM #{table} WHERE Key_name = #{conn.quote(index_name)}")
    result.respond_to?(:count) ? result.count.positive? : result.to_a.any?
  rescue StandardError
    false
  end

  def default_indexes
    INDEX_NAMES.transform_values { false }
  end
end
