# frozen_string_literal: true

# MariaDB stores query-log tags inside trigger bodies: development enables
# config.active_record.query_log_tags_enabled, so triggers created through
# ActiveRecord carry a trailing /*application='GraphMem'*/. mysqldump (and
# Rails' db:schema:dump) writes that tag just before the trigger's "*/;;"
# terminator, which leaves a stray "*/" in structure.sql — db:schema:load
# then fails with ERROR 1064 on fresh databases. Strip the tag after every
# dump so the committed file stays loadable (see PR #97).
#
# The snapshot prerequisite + StructureDumpGuard additionally prevent dumps
# taken from a DB that never ran `embeddings:add_indexes` from degrading the
# committed file (VECTOR KEYs, NOT NULL columns and insert triggers would go
# missing — CI treats that as a broken structure.sql).
namespace :db do
  task snapshot_structure_sql: :environment do
    path = Rails.root.join("db/structure.sql")
    StructureDumpGuard.snapshot = path.read if path.exist?
  end
end

# This app is multi-database, so `db:migrate` can reach the dump through
# the per-database task (`db:schema:dump:primary`) as well as the shared
# one — the hook must cover both or the cleaner/guard silently skip dumps
# run via the namespaced migrate tasks. Only primary writes
# db/structure.sql; queue dumps to queue_structure.sql are untouched.
[ "db:schema:dump", "db:schema:dump:primary" ].each do |task_name|
  next unless Rake::Task.task_defined?(task_name)

  Rake::Task[task_name].enhance([ "db:snapshot_structure_sql" ]) do
    StructureDumpGuard.process_file!(Rails.root.join("db/structure.sql"))
  end
end
