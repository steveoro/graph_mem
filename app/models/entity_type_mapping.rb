# frozen_string_literal: true

class EntityTypeMapping < ApplicationRecord
  validates :canonical_type, presence: true
  validates :variant, presence: true, uniqueness: { case_sensitive: false }

  # Returns the canonical type for a given variant string, or nil if no mapping exists.
  def self.canonicalize(raw_type)
    return nil if raw_type.blank?

    mapping = find_by("LOWER(variant) = ?", raw_type.strip.downcase)
    mapping&.canonical_type
  end
end
