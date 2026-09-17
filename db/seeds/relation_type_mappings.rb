# frozen_string_literal: true

puts "Seeding relation type mappings..."
count = 0

GraphVocabulary::RELATION_TYPE_MAPPINGS.each do |canonical, variants|
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    RelationTypeMapping.find_or_create_by!(variant: variant.downcase) do |mapping|
      mapping.canonical_type = canonical
    end
    count += 1
  end
end

puts "Seeded #{count} relation type mappings."
