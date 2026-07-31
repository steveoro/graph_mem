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
  end
end
