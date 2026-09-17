# frozen_string_literal: true

puts "Seeding entity type mappings..."
count = 0

GraphVocabulary::ENTITY_TYPE_MAPPINGS.each do |canonical, variants|
  # The canonical type itself is also a variant (for exact matches)
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    EntityTypeMapping.find_or_create_by!(variant: variant.downcase) do |m|
      m.canonical_type = canonical
    end
    count += 1
  end
end

puts "Seeded #{count} entity type mappings."
