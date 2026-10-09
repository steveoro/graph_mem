# frozen_string_literal: true

puts "Seeding entity type mappings..."
count = 0

GraphVocabulary::ENTITY_TYPE_MAPPINGS.each do |canonical, variants|
  # The canonical type itself is also a variant (for exact matches)
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    mapping = EntityTypeMapping.find_or_initialize_by(variant: variant.downcase)
    mapping.update!(canonical_type: canonical)
    count += 1
  end
end

puts "Seeded #{count} entity type mappings."

# Invalidate the process cache: an in-process re-seed must take effect
# without a restart.
EntityTypeMapping.reset_canonicalize_cache!
