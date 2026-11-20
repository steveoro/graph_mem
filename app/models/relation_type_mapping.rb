# frozen_string_literal: true

class RelationTypeMapping < ApplicationRecord
  validates :canonical_type, presence: true
  validates :variant, presence: true, uniqueness: { case_sensitive: false }

  # Memoized per-process with a TTL, like EntityTypeMapping: bounds
  # cross-process staleness after a re-seed to under a minute.
  CANONICALIZE_TTL = 60.seconds

  # Returns the canonical type for a given variant string, or nil if no mapping exists. A variant
  # the table doesn't hold falls back to the code-owned vocabulary
  # (`GraphVocabulary::RELATION_TYPE_MAPPINGS`), so the mappings work without a seeded table and a
  # table row (an operator's choice) wins over the code. Nothing is written here.
  #
  # @param raw_type [String, nil] a relation type or variant; only trimmed and lower-cased here
  #   (see `MemoryRelation.canonical_relation_type` for the full fold)
  # @return [String, nil]
  def self.canonicalize(raw_type)
    return nil if raw_type.blank?

    key = raw_type.to_s.strip.downcase
    # A canonical name always maps to itself — upgraded databases may
    # carry a stale variant row for it (e.g. `belongs_to` seeded under
    # `part_of` before it became its own canonical type), and the
    # vocabulary owns that identity.
    return key if GraphVocabulary::RELATION_TYPES.include?(key)

    @canonical_cache ||= {}
    entry = @canonical_cache[key]
    return entry[:value] if entry && entry[:at] > CANONICALIZE_TTL.ago

    value = table_type(key) || vocabulary_type(key)
    @canonical_cache[key] = { value: value, at: Time.current }
    value
  end

  # @param key [String] a downcased variant
  # @return [String, nil] the canonical type of the table row for the variant; a row stored with
  #   spaces or hyphens ("needs synth") also answers to its underscore spelling ("needs_synth")
  def self.table_type(key)
    (find_by("LOWER(variant) = ?", key) ||
      find_by("REPLACE(REPLACE(LOWER(variant), ' ', '_'), '-', '_') = ?", key))&.canonical_type
  end
  private_class_method :table_type

  # @param key [String] a downcased variant
  # @return [String, nil] the GraphVocabulary canonical type the variant belongs to
  def self.vocabulary_type(key)
    @vocabulary_variants ||= GraphVocabulary::RELATION_TYPE_MAPPINGS.each_with_object({}) do |(type, variants), map|
      variants.each { |variant| map[variant.downcase] = type }
    end
    @vocabulary_variants[key]
  end
  private_class_method :vocabulary_type

  # Clears the process cache — call after re-seeding/upserting mappings so
  # new or changed variants take effect without a restart.
  def self.reset_canonicalize_cache!
    @canonical_cache = {}
  end
end
