# frozen_string_literal: true

# Installs DB-side guards for MariaDB VECTOR columns that must remain NOT NULL
# while ANN indexes are active. The zero vector is only a placeholder; model
# callbacks replace it with the real embedding after the row is created.
#
# install! is convergent: it re-creates a trigger only when it is missing or
# its stored body drifted, because rebuilding a MariaDB trigger is DROP +
# CREATE — two auto-committed DDL statements with a window in between where
# inserts would skip the guard. A healthy DB is left untouched, so re-running
# carries no recreate window; a run interrupted mid-recreate leaves mixed
# state that the next run repairs.
#
# Returns a report hash so callers (EmbeddingIndexManager) can tell "repaired"
# apart from "already correct" and surface skips instead of claiming success.
class EmbeddingVectorTriggerManager
  TABLE_TRIGGERS = {
    "memory_entities" => "trg_memory_entities_embedding_bi",
    "memory_observations" => "trg_memory_observations_embedding_bi"
  }.freeze

  class << self
    def install!(only: nil)
      new.install!(only: only)
    end

    def drop!
      new.drop!
    end
  end

  # @return [Hash] { installed: [trigger names created/recreated],
  #                  unchanged: [trigger names already correct],
  #                  skipped:   [reasons a trigger could not be installed] }
  def install!(only: nil)
    result = { installed: [], unchanged: [], skipped: [] }

    TABLE_TRIGGERS.each do |table, trigger|
      next if only && !Array(only).map(&:to_s).include?(table)

      if !connection.table_exists?(table)
        result[:skipped] << "#{trigger} (table #{table} missing)"
      elsif !embedding_column_not_null?(table)
        result[:skipped] << "#{trigger} (#{table}.embedding still nullable — set it NOT NULL first)"
      elsif trigger_body_correct?(trigger, table)
        result[:unchanged] << trigger
      else
        drop_trigger(trigger)
        connection.execute <<~SQL.squish
          CREATE TRIGGER #{trigger}
          BEFORE INSERT ON #{table}
          FOR EACH ROW
          SET NEW.embedding = IFNULL(NEW.embedding, #{zero_vector_sql})
        SQL
        result[:installed] << trigger
      end
    end

    result
  end

  def drop!
    TABLE_TRIGGERS.each_value { |trigger| drop_trigger(trigger) }
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def embedding_column_not_null?(table)
    column = connection.columns(table).find { |col| col.name == "embedding" }
    column.present? && column.null == false
  rescue StandardError
    false
  end

  # Live trigger definition from information_schema — nil only when the
  # trigger is absent. Query errors propagate: treating them as "absent" would
  # recreate a healthy trigger (non-atomic DROP + CREATE).
  def trigger_definition(trigger)
    connection.select_one(
      "SELECT ACTION_STATEMENT, EVENT_MANIPULATION, ACTION_TIMING, EVENT_OBJECT_TABLE " \
      "FROM information_schema.TRIGGERS " \
      "WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = #{connection.quote(trigger)}"
    )
  end

  # MariaDB normalizes case/whitespace in stored bodies and may append
  # query-log tags (/*application='GraphMem'*/), so compare semantics, not
  # literals: an IFNULL(NEW.embedding, VEC_FromText(<dims>-vector)) guard.
  # Identifiers may come back backticked (NEW.`embedding`).
  def trigger_body_correct?(trigger, table)
    definition = trigger_definition(trigger)
    return false if definition.nil?
    return false unless definition["EVENT_OBJECT_TABLE"] == table &&
                        definition["EVENT_MANIPULATION"].to_s.casecmp?("INSERT") &&
                        definition["ACTION_TIMING"].to_s.casecmp?("BEFORE")

    body = definition["ACTION_STATEMENT"].to_s
    body.match?(/IFNULL\s*\(\s*`?NEW`?\.`?embedding`?/i) &&
      body.match?(/vec_fromtext/i) &&
      body[/repeat\('0,',\s*(\d+)/i, 1].to_i == dims - 1
  end

  def drop_trigger(trigger)
    connection.execute("DROP TRIGGER IF EXISTS #{trigger}")
  end

  def zero_vector_sql
    repeats = [ dims - 1, 0 ].max
    "VEC_FromText(CONCAT('[', REPEAT('0,', #{repeats}), '0]'))"
  end

  def dims
    EmbeddingConfig.resolved_config[:dims].to_i
  end
end
