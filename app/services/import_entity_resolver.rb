# frozen_string_literal: true

# Keeps import matching and execution aligned on canonical entity types.
class ImportEntityResolver
  class << self
    def canonical_type(raw_type)
      EntityTypeMapping.canonicalize(raw_type) || raw_type.to_s.strip
    end

    def find_by_name_and_type(name, raw_type)
      MemoryEntity.find_by(name: name, entity_type: canonical_type(raw_type))
    end

    # Read-only name-only lookup for Class↔Module same-name collisions
    # (`module Billing` under v1.49 stored `Class:Billing`; a mixin reference
    # stub vs the declaring repo's real type). Matching must NEVER write —
    # this only returns the colliding entity; ImportExecutionStrategy
    # decides whether retyping is allowed.
    def class_module_collision(name, raw_type)
      type = canonical_type(raw_type)
      return unless %w[Class Module].include?(type)

      MemoryEntity.find_by(name: name, entity_type: %w[Class Module] - [ type ])
    end
  end
end
