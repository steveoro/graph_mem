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

Rake::Task["db:schema:dump"].enhance([ "db:snapshot_structure_sql" ]) do
  path = Rails.root.join("db/structure.sql")
  next unless path.exist?

  original = path.read
  begin
    cleaned = StructureDumpGuard.call(StructureDumpCleaner.call(original))
  rescue StructureDumpGuard::UnrecoverableDumpError => e
    # The fresh dump carries migrations the snapshot lacks — restoring would
    # lose their DDL, and leaving the degraded file in place makes it
    # committable. Write the snapshot back and fail the task instead.
    path.write(StructureDumpGuard.snapshot) if StructureDumpGuard.snapshot.present?
    abort "[db:schema:dump] ERROR: #{e.message}"
  end
  path.write(cleaned) if cleaned != original
end
