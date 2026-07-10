# frozen_string_literal: true

# MariaDB VECTOR indexes require NOT NULL columns, but ActiveRecord cannot bind
# VEC_FromText(...) during ordinary inserts. These triggers provide a zero-vector
# placeholder so model callbacks can immediately replace it with a real vector.
class AddEmbeddingInsertTriggers < ActiveRecord::Migration[8.0]
  TABLE_TRIGGERS = {
    "memory_entities" => "trg_memory_entities_embedding_bi",
    "memory_observations" => "trg_memory_observations_embedding_bi"
  }.freeze

  def up
    TABLE_TRIGGERS.each do |table, trigger|
      next unless embedding_column_not_null?(table)

      execute "DROP TRIGGER IF EXISTS #{trigger}"
      execute <<~SQL.squish
        CREATE TRIGGER #{trigger}
        BEFORE INSERT ON #{table}
        FOR EACH ROW
        SET NEW.embedding = IFNULL(NEW.embedding, #{zero_vector_sql})
      SQL
    end
  end

  def down
    TABLE_TRIGGERS.each_value { |trigger| execute "DROP TRIGGER IF EXISTS #{trigger}" }
  end

  private

  def embedding_column_not_null?(table)
    return false unless table_exists?(table)

    column = connection.columns(table).find { |col| col.name == "embedding" }
    column.present? && column.null == false
  rescue StandardError
    false
  end

  def zero_vector_sql
    "VEC_FromText(CONCAT('[', REPEAT('0,', 767), '0]'))"
  end
end
