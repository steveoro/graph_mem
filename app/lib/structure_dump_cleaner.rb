# frozen_string_literal: true

# Strips query-log marginalia from db/structure.sql.
#
# MariaDB stores query-log tags inside trigger bodies: development enables
# config.active_record.query_log_tags_enabled, so triggers created through
# ActiveRecord carry a trailing /*application='GraphMem'*/. mysqldump (and
# Rails' db:schema:dump) writes that tag between the trigger body and the
# closing "*/;;" terminator — with or without whitespace — which leaves a
# stray "*/" in the file and makes db:schema:load fail with ERROR 1064.
class StructureDumpCleaner
  # Matches the tag plus whatever spacing precedes the "*/;;" terminator;
  # replacing with a single space restores the canonical one-line form.
  MARGINALIA = %r{ ?/\*application='[^']*'\*/\s*(?=\*/;;)}.freeze

  def self.call(content)
    content.gsub(MARGINALIA, " ")
  end
end
