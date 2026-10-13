# frozen_string_literal: true

# Upgraded databases run migrations without re-running `db:seed`, so new
# vocabulary entries must be seeded here too — otherwise `caused_by` and its
# variants stay unmapped (usable only as literal types) on existing installs.
# Mirrors `db/seeds/relation_type_mappings.rb` (find_or_initialize_by + cache
# reset); kept narrow to this release's new entries.
class SeedCausedByRelationMappings < ActiveRecord::Migration[8.1]
  CANONICAL = "caused_by"
  VARIANTS = %w[resulted_from triggered_by consequence_of].freeze

  def up
    ([ CANONICAL ] + VARIANTS).each do |variant|
      mapping = RelationTypeMapping.find_or_initialize_by(variant: variant.downcase)
      # Only write NEW variants or ones already pointing at this canonical —
      # never clobber an operator's deliberate remap (e.g. triggered_by→depends_on).
      next if mapping.persisted? && mapping.canonical_type != CANONICAL

      mapping.update!(canonical_type: CANONICAL)
    end
    RelationTypeMapping.reset_canonicalize_cache!
  end

  def down
    RelationTypeMapping.where(variant: ([ CANONICAL ] + VARIANTS).map(&:downcase)).delete_all
    RelationTypeMapping.reset_canonicalize_cache!
  end
end
