# frozen_string_literal: true

puts "Seeding relation type mappings..."
count = 0

GraphVocabulary::RELATION_TYPE_MAPPINGS.each do |canonical, variants|
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    mapping = RelationTypeMapping.find_or_initialize_by(variant: variant.downcase)
    mapping.update!(canonical_type: canonical)
    count += 1
  end
end

puts "Seeded #{count} relation type mappings."
