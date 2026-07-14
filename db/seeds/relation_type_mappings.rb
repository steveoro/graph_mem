# frozen_string_literal: true

CANONICAL_RELATION_TYPES = {
  "part_of" => %w[partof belongs_to child_of contained_in],
  "depends_on" => %w[dependson requires prerequisite_of],
  "relates_to" => %w[related_to relatedto associated_with connected_to connects_to],
  "implements" => %w[implementation_of provides],
  "solves" => %w[resolves fixes solution_for]
}.freeze

puts "Seeding relation type mappings..."
count = 0

CANONICAL_RELATION_TYPES.each do |canonical, variants|
  ([ canonical ] + variants).uniq(&:downcase).each do |variant|
    RelationTypeMapping.find_or_create_by!(variant: variant.downcase) do |mapping|
      mapping.canonical_type = canonical
    end
    count += 1
  end
end

puts "Seeded #{count} relation type mappings."
