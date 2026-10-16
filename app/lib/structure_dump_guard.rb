# frozen_string_literal: true

# Guards db/structure.sql against dumps taken from databases where the
# embedding indexes/triggers were never installed.
#
# AddVectorIndexes defers VECTOR INDEX creation to `rake embeddings:add_indexes`
# (the columns start nullable so backfill can run first), and
# AddEmbeddingInsertTriggers only creates its zero-vector triggers once the
# columns are NOT NULL. A db:schema:dump from a DB that never ran
# add_indexes therefore omits the NOT NULL flags, VECTOR KEYs and trigger
# blocks — silently degrading the committed file (CI spec caught this once).
#
# The guard restores the previous canonical dump when a fresh dump regresses,
# so an unindexed machine can never produce a committable structure.sql — but
# only when the fresh dump carries no schema_migrations versions the snapshot
# lacks: a new migration's DDL must never be silently discarded, so that case
# raises UnrecoverableDumpError and the dump task aborts instead. Operators
# who intentionally dropped the indexes can bypass with
# GRAPH_MEM_ALLOW_UNINDEXED_DUMP=1.
class StructureDumpGuard
  EMBEDDING_COLUMN = /`embedding` vector\(\d+\)/i
  NOT_NULL_EMBEDDING = /`embedding` vector\(\d+\) NOT NULL/i
  MIGRATIONS_INSERT = /INSERT INTO `schema_migrations` \(version\) VALUES\s*(.*?);/m

  # Raised when a degraded dump carries migrations the snapshot lacks —
  # restoring the snapshot would erase their DDL, so the dump task aborts.
  class UnrecoverableDumpError < StandardError; end

  class << self
    # Content of db/structure.sql as it was before the current dump (set by
    # the db:snapshot_structure_sql prerequisite task).
    attr_accessor :snapshot

    # Returns the content that should end up in db/structure.sql: the fresh
    # dump when it is canonical, the previous dump when the fresh one lost
    # the indexed embedding schema.
    def call(content)
      return content if ENV["GRAPH_MEM_ALLOW_UNINDEXED_DUMP"].present?
      return content if canonical?(content)

      if content.match?(EMBEDDING_COLUMN)
        warn_unindexed_dump(content) || content
      else
        warn "[db:schema:dump] WARNING: structure.sql contains no embedding " \
             "VECTOR columns — the source DB predates MariaDB 11.7 support. " \
             "Do not commit this file."
        content
      end
    end

    # Post-dump processing for db/structure.sql: strips marginalia tags,
    # then applies the guard. When the dump is unrecoverable (degraded AND
    # carrying schema_migrations versions the snapshot lacks), restoring
    # would erase the new migration's DDL and leaving the file in place
    # makes it committable — so the snapshot is written back and the task
    # aborts with a non-zero exit instead.
    def process_file!(path)
      return unless path.exist?

      original = path.read
      cleaned =
        begin
          call(StructureDumpCleaner.call(original))
        rescue UnrecoverableDumpError => e
          path.write(snapshot) if snapshot.present?
          abort "[db:schema:dump] ERROR: #{e.message}"
        end
      path.write(cleaned) if cleaned != original
    end

    # True when the dump carries the full indexed embedding schema: both
    # NOT NULL columns, both VECTOR KEYs, both insert triggers.
    def canonical?(content)
      return false if content.blank?

      content.scan(NOT_NULL_EMBEDDING).size == 2 &&
        EmbeddingVectorTriggerManager::TABLE_TRIGGERS.all? do |table, trigger|
          content.match?(%r{VECTOR KEY `idx_#{table}_embedding`}i) &&
            content.match?(/TRIGGER #{trigger} .*? \*\/;;/m)
        end
    end

    private

    def warn_unindexed_dump(content)
      if snapshot.present? && canonical?(snapshot)
        new_versions = migration_versions(content) - migration_versions(snapshot)
        # Restoring would erase the DDL and schema_migrations rows of
        # migrations the snapshot predates — fail loudly instead.
        if new_versions.any?
          raise UnrecoverableDumpError,
                "dump came from a DB without the embedding indexes/triggers " \
                "AND carries schema_migrations versions the previous " \
                "structure.sql lacks (#{new_versions.join(', ')}). Not " \
                "restoring — that would drop the new migration's schema. " \
                "Rerun the dump from an indexed DB, or set " \
                "GRAPH_MEM_ALLOW_UNINDEXED_DUMP=1 to keep this output."
        end
        warn "[db:schema:dump] WARNING: dump came from a DB without the " \
             "embedding indexes/triggers (embeddings:add_indexes never ran). " \
             "Restored the previous structure.sql — rerun the dump from an " \
             "indexed DB, or set GRAPH_MEM_ALLOW_UNINDEXED_DUMP=1 to keep " \
             "this output."
        snapshot
      else
        warn "[db:schema:dump] WARNING: dump came from a DB without the " \
             "embedding indexes/triggers and no previous canonical dump is " \
             "available to restore — do not commit this structure.sql."
        nil
      end
    end

    # schema_migrations versions present in a dump ("('20261013120000'),\n...")
    def migration_versions(content)
      content[MIGRATIONS_INSERT, 1].to_s.scan(/'(\d+)'/).flatten
    end
  end
end
