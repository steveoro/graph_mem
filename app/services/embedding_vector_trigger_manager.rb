# frozen_string_literal: true

# Installs DB-side guards for MariaDB VECTOR columns that must remain NOT NULL
# while ANN indexes are active. The zero vector is only a placeholder; model
# callbacks replace it with the real embedding after the row is created.
class EmbeddingVectorTriggerManager
  TABLE_TRIGGERS = {
    "memory_entities" => "trg_memory_entities_embedding_bi",
    "memory_observations" => "trg_memory_observations_embedding_bi"
  }.freeze

  class << self
    def install!
      new.install!
    end

    def drop!
      new.drop!
    end
  end

  def install!
    TABLE_TRIGGERS.each do |table, trigger|
      next unless embedding_column_not_null?(table)

      drop_trigger(trigger)
      connection.execute <<~SQL.squish
        CREATE TRIGGER #{trigger}
        BEFORE INSERT ON #{table}
        FOR EACH ROW
        SET NEW.embedding = IFNULL(NEW.embedding, #{zero_vector_sql})
      SQL
    end
  end

  def drop!
    TABLE_TRIGGERS.each_value { |trigger| drop_trigger(trigger) }
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def embedding_column_not_null?(table)
    return false unless connection.table_exists?(table)

    column = connection.columns(table).find { |col| col.name == "embedding" }
    column.present? && column.null == false
  rescue StandardError
    false
  end

  def drop_trigger(trigger)
    connection.execute("DROP TRIGGER IF EXISTS #{trigger}")
  end

  def zero_vector_sql
    dims = EmbeddingConfig.resolved_config[:dims].to_i
    repeats = [ dims - 1, 0 ].max
    "VEC_FromText(CONCAT('[', REPEAT('0,', #{repeats}), '0]'))"
  end
end
