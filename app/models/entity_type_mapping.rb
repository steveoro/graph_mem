# frozen_string_literal: true

class EntityTypeMapping < ApplicationRecord
  validates :canonical_type, presence: true
  validates :variant, presence: true, uniqueness: { case_sensitive: false }

  # Returns the canonical type for a given variant string, or nil if no mapping exists.
  # Memoized per-process: mappings are seed data, and hot paths (imports,
  # relation writes) canonicalize the same few types thousands of times.
  def self.canonicalize(raw_type)
    return nil if raw_type.blank?

    key = raw_type.to_s.strip.downcase
    @canonical_cache ||= {}
    return @canonical_cache[key] if @canonical_cache.key?(key)

    @canonical_cache[key] = find_by("LOWER(variant) = ?", key)&.canonical_type
  end

  # Clears the process cache — call after re-seeding/upserting mappings so
  # new or changed variants take effect without a restart.
  def self.reset_canonicalize_cache!
    @canonical_cache = {}
  end
end
