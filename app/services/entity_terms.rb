# frozen_string_literal: true

# The terms a text can name an entity by (1.77.0, shared by ProjectScanValidator and
# FactKeywords::TermIndex): its name and each alias (aliases split on , | ;), downcased, at least
# MIN_LENGTH characters, unique.
#
#   EntityTerms.for(entity) # => ["gogglesdb::badge", "badge", "goggles_db/badge"]
module EntityTerms
  # Shorter terms match too much text to mean an entity.
  MIN_LENGTH = 3

  module_function

  # @param entity [#name, #aliases] a MemoryEntity (or anything with a name and an aliases string)
  # @return [Array<String>]
  def for(entity)
    terms = [ entity.name.to_s.strip ]
    terms += entity.aliases.to_s.split(/[,|;]/).map(&:strip) if entity.aliases.present?
    terms.map(&:downcase).reject(&:blank?).reject { |term| term.length < MIN_LENGTH }.uniq
  end
end
