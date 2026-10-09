# frozen_string_literal: true

class EntityTypeMapping < ApplicationRecord
  validates :canonical_type, presence: true
  validates :variant, presence: true, uniqueness: { case_sensitive: false }

  # Memoized per-process with a TTL: mappings are seed data, and hot paths
  # (imports, relation writes) canonicalize the same few types thousands of
  # times. The TTL bounds staleness — a re-seed in another process (seeds
  # only clear their own process's cache) takes effect within a minute
  # instead of needing a restart.
  CANONICALIZE_TTL = 60.seconds

  # Returns the canonical type for a given variant string, or nil if no mapping exists.
  def self.canonicalize(raw_type)
    return nil if raw_type.blank?

    key = raw_type.to_s.strip.downcase
    @canonical_cache ||= {}
    entry = @canonical_cache[key]
    return entry[:value] if entry && entry[:at] > CANONICALIZE_TTL.ago

    value = find_by("LOWER(variant) = ?", key)&.canonical_type
    @canonical_cache[key] = { value: value, at: Time.current }
    value
  end

  # Clears the process cache — call after re-seeding/upserting mappings so
  # new or changed variants take effect without a restart.
  def self.reset_canonicalize_cache!
    @canonical_cache = {}
  end
end
