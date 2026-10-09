# frozen_string_literal: true

# MariaDB stores query-log tags inside trigger bodies: development enables
# config.active_record.query_log_tags_enabled, so triggers created through
# ActiveRecord carry a trailing /*application='GraphMem'*/. mysqldump (and
# Rails' db:schema:dump) writes that tag just before the trigger's "*/;;"
# terminator, which leaves a stray "*/" in structure.sql — db:schema:load
# then fails with ERROR 1064 on fresh databases. Strip the tag after every
# dump so the committed file stays loadable (see PR #97).
Rake::Task["db:schema:dump"].enhance do
  path = Rails.root.join("db/structure.sql")
  next unless path.exist?

  original = path.read
  cleaned = StructureDumpCleaner.call(original)
  path.write(cleaned) if cleaned != original
end
