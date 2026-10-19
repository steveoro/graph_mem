# frozen_string_literal: true

# Manages VECTOR index DDL for embedding columns (MariaDB 11.7+).
#
# add_indexes! is convergent — safe to re-run: it creates what is missing,
# skips what is already correct, and reports (never touches) pieces it cannot
# safely repair. The main fail-safe: a NOT NULL column that already carries an
# index is never ALTERed — a default/dimensions drift there would force
# rebuilding the VECTOR index, so it is reported as a warning with the
# `drop_indexes` + `add_indexes` repair path instead.
#
# The result's `converged` flag is false whenever drift remains — callers
# (rake task, operator UI) must surface it instead of reporting plain success.
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

  # @return [Hash] { success:, converged:, performed:, skipped:, warnings:,
  #                  message:, indexes: }
  def add_indexes!
    conn = ActiveRecord::Base.connection
    dims = EmbeddingConfig.resolved_config[:dims]

    missing = EmbeddingIndexStatus::INDEX_NAMES.keys.reject do |table|
      conn.column_exists?(table, :embedding)
    end
    if missing.any?
      raise PrecheckError, "embedding columns don't exist. Run migrations first."
    end

    entity_nulls = MemoryEntity.missing_embedding.count
    obs_nulls = MemoryObservation.missing_embedding.count

    if entity_nulls.positive? || obs_nulls.positive?
      raise PrecheckError,
            "#{entity_nulls} entities and #{obs_nulls} observations still have NULL embeddings. " \
            "Run backfill first."
    end

    performed = []
    skipped = []
    warnings = []

    EmbeddingIndexStatus::INDEX_NAMES.each do |table, index_name|
      table = table.to_s
      column = embedding_column(conn, table)
      index_names = index_names_on_embedding(conn, table)

      converge_column!(conn, table, column, index_names, dims, performed, skipped, warnings)
      converge_index!(conn, table, index_name, index_names, performed, skipped, warnings)

      # Per table, right after it converges: a failure on a later table must
      # not leave this one NOT NULL + indexed but without its insert trigger.
      trigger_report = EmbeddingVectorTriggerManager.install!(only: [ table ])
      if trigger_report[:installed].any?
        performed << "triggers (re)installed: #{trigger_report[:installed].join(', ')}"
      end
      skipped.concat(trigger_report[:unchanged].map { |name| "#{name} already correct" })
      warnings.concat(trigger_report[:skipped])
    end

    EmbeddingService.reset_vector_cache!
    EmbeddingService.reset_instance!

    {
      success: true,
      converged: warnings.empty?,
      performed: performed,
      skipped: skipped,
      warnings: warnings,
      message: build_message(performed, skipped, warnings),
      indexes: EmbeddingIndexStatus.indexes
    }
  end

  def drop_indexes!
    conn = ActiveRecord::Base.connection
    dims = EmbeddingConfig.resolved_config[:dims]

    EmbeddingVectorTriggerManager.drop!

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

  # Ensures NOT NULL + zero-vector DEFAULT on the column. Always ALTERs a
  # nullable column (required before indexing); never ALTERs a NOT NULL column
  # that carries an index — drift there is reported, not touched.
  def converge_column!(conn, table, column, index_names, dims, performed, skipped, warnings)
    drift = column.null ? nil : column_drift(column, dims)

    if drift && index_names.empty? && dims_mismatch?(column, dims) && rows_present?(conn, table)
      # Existing vectors have the old dimensions — ALTER would fail or invalidate them.
      warnings << "#{table}.embedding #{drift} and the table has rows — " \
                  "not altering; run embeddings:regenerate after changing dims"
    elsif column.null || (drift && index_names.empty?)
      execute_ddl(
        conn,
        "ALTER TABLE #{table} MODIFY embedding VECTOR(#{dims}) " \
        "NOT NULL DEFAULT #{zero_vector_sql(dims)}"
      )
      performed << "#{table}.embedding set NOT NULL with zero-vector default"
    elsif drift
      warnings << "#{table}.embedding #{drift} but #{index_names.join(', ')} is present — " \
                  "not altering an indexed column; run embeddings:drop_indexes then add_indexes to repair"
    else
      skipped << "#{table}.embedding already NOT NULL"
    end
  end

  # Adds the canonical VECTOR index. A same-named index is skipped; an index
  # under a different name on the same column is reported (MariaDB allows one
  # vector index per column — a blind ADD would collide).
  def converge_index!(conn, table, index_name, index_names, performed, skipped, warnings)
    if index_names.include?(index_name)
      skipped << "#{index_name} already present"
    elsif index_names.any?
      warnings << "#{table}.embedding already indexed as #{index_names.join(', ')} " \
                  "— not adding #{index_name}"
    else
      execute_ddl conn, <<~SQL
        ALTER TABLE #{table}
          ADD VECTOR INDEX #{index_name} (embedding)
          DISTANCE=cosine
      SQL
      performed << "#{index_name} created"
    end
  end

  def embedding_column(conn, table)
    conn.columns(table).find { |col| col.name == "embedding" }
  end

  # Names of the VECTOR indexes on <table>.embedding (other index types on the
  # column are irrelevant to ANN search and must not block creating one).
  def index_names_on_embedding(conn, table)
    conn.select_all("SHOW INDEX FROM #{table} WHERE Column_name = 'embedding'")
        .select { |row| row["Index_type"].to_s.casecmp?("VECTOR") }
        .map { |row| row["Key_name"] }
  end

  def dims_mismatch?(column, dims)
    column_dims(column) != dims
  end

  def rows_present?(conn, table)
    conn.select_value("SELECT 1 FROM #{table} LIMIT 1").present?
  end

  # DDL failures surface as EmbeddingIndexManager::Error so the rake task and
  # operator controller report them instead of a raw stack trace.
  def execute_ddl(conn, sql)
    conn.execute(sql)
  rescue ActiveRecord::StatementInvalid => e
    raise Error, "#{e.message.lines.first.to_s.strip} (re-run embeddings:add_indexes after fixing; it is safe to repeat)"
  end

  # nil when the column already matches the configured schema, else a
  # human-readable drift description.
  def column_drift(column, dims)
    drift = []
    actual_dims = column_dims(column)
    drift << "is vector(#{actual_dims || 'unknown'}), expected vector(#{dims})" if actual_dims != dims
    drift << "has unexpected default #{raw_default(column).inspect}" unless zero_vector_default?(column, dims)
    drift.any? ? drift.join(" and ") : nil
  end

  # MariaDB normalizes expression defaults (lowercase inner functions,
  # stripped whitespace — see db/structure.sql) and the adapter reports them
  # in `default_function`, not `default`.
  def zero_vector_default?(column, dims)
    default = raw_default(column)
    default.match?(/vec_fromtext/i) &&
      default[/repeat\('0,',\s*(\d+)/i, 1].to_i == dims - 1
  end

  def raw_default(column)
    (column.default || column.default_function).to_s.gsub(/\s+/, "")
  end

  def column_dims(column)
    column.sql_type.to_s[/vector\((\d+)\)/i, 1]&.to_i
  end

  def build_message(performed, skipped, warnings)
    headline =
      if warnings.any?
        "Finished with warnings — database not fully converged."
      elsif performed.any? { |step| step.end_with?("created") }
        "VECTOR INDEX active — ANN search enabled."
      elsif performed.any?
        "Embedding indexes converged."
      else
        "Nothing to do — embedding indexes already converged."
      end

    details = []
    details << "Done: #{performed.join('; ')}." if performed.any?
    details << "Skipped: #{skipped.join('; ')}." if skipped.any?
    details << "WARNINGS: #{warnings.join('; ')}." if warnings.any?
    ([ headline ] + details).join(" ")
  end

  def zero_vector_sql(dims)
    repeats = dims - 1
    "(VEC_FromText(CONCAT('[', REPEAT('0,', #{repeats}), '0]')))"
  end
end
