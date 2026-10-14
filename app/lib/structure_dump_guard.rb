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
# so an unindexed machine can never produce a committable structure.sql. It
# never aborts: db:migrate auto-dump and deploy flows stay green. Operators
# who intentionally dropped the indexes can bypass with
# GRAPH_MEM_ALLOW_UNINDEXED_DUMP=1.
class StructureDumpGuard
  EMBEDDING_COLUMN = /`embedding` vector\(\d+\)/i
  NOT_NULL_EMBEDDING = /`embedding` vector\(\d+\) NOT NULL/i

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
        warn_unindexed_dump || content
      else
        warn "[db:schema:dump] WARNING: structure.sql contains no embedding " \
             "VECTOR columns — the source DB predates MariaDB 11.7 support. " \
             "Do not commit this file."
        content
      end
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

    def warn_unindexed_dump
      if snapshot.present? && canonical?(snapshot)
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
  end
end
