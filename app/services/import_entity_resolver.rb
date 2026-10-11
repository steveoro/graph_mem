# frozen_string_literal: true

# Keeps import matching and execution aligned on canonical entity types.
class ImportEntityResolver
  class << self
    def canonical_type(raw_type)
      EntityTypeMapping.canonicalize(raw_type) || raw_type.to_s.strip
    end

    def find_by_name_and_type(name, raw_type)
      type = canonical_type(raw_type)
      MemoryEntity.find_by(name: name, entity_type: type) ||
        retype_class_module(name, type)
    end

    # Entity names are globally unique, so `module Billing` imported as
    # `Class:Billing` under v1.49 (or a `Class:`-typed reference stub)
    # collides with a later `Module:Billing` payload. Class/Module are the
    # same declaration kind — retype the stored entity instead of
    # duplicating. Any other type pair keeps strict name+type matching.
    def retype_class_module(name, type)
      return unless %w[Class Module].include?(type)

      entity = MemoryEntity.find_by(name: name, entity_type: %w[Class Module] - [ type ])
      entity&.update!(entity_type: type) ? entity : nil
    end
  end
end
