# frozen_string_literal: true

# Central definition of relation behavior: hierarchy, symmetry, single-parent
# constraints, and cycle protection for graph integrity.
class RelationSemantics
  HIERARCHICAL_TYPES = %w[part_of].freeze
  SINGLE_PARENT_TYPES = %w[part_of].freeze
  SYMMETRIC_TYPES = %w[relates_to].freeze
  CYCLE_PROHIBITED_TYPES = %w[part_of].freeze
  CHILD_RELATION_TYPES = HIERARCHICAL_TYPES

  class ValidationError < StandardError; end

  class << self
    def canonicalize(relation_type)
      MemoryRelation.canonical_relation_type(relation_type)
    end

    def hierarchical?(relation_type)
      HIERARCHICAL_TYPES.include?(canonicalize(relation_type))
    end

    def single_parent?(relation_type)
      SINGLE_PARENT_TYPES.include?(canonicalize(relation_type))
    end

    def symmetric?(relation_type)
      SYMMETRIC_TYPES.include?(canonicalize(relation_type))
    end

    def cycle_prohibited?(relation_type)
      CYCLE_PROHIBITED_TYPES.include?(canonicalize(relation_type))
    end

    def child_relation_types
      CHILD_RELATION_TYPES
    end

    def validate_create!(from_entity_id:, to_entity_id:, relation_type:)
      type = canonicalize(relation_type)
      from_id = from_entity_id.to_i
      to_id = to_entity_id.to_i

      raise ValidationError, "Cannot create a self-referential relation" if from_id == to_id

      if cycle_prohibited?(type) && would_create_cycle?(from_id, to_id, relation_type: type)
        raise ValidationError, "Creating #{type} relation would introduce a cycle"
      end

      if single_parent?(type)
        existing = MemoryRelation.where(from_entity_id: from_id, relation_type: type).where.not(to_entity_id: to_id)
        if existing.exists?
          raise ValidationError, "Entity already has a #{type} parent; use move_to_parent instead"
        end
      end

      true
    end

    def would_create_cycle?(from_entity_id, to_entity_id, relation_type: "part_of")
      return false unless cycle_prohibited?(relation_type)

      descendant_ids(from_entity_id, relation_type: relation_type).include?(to_entity_id.to_i)
    end

    def descendant_ids(entity_id, relation_type: "part_of")
      type = canonicalize(relation_type)
      ids = Set.new
      queue = [ entity_id.to_i ]

      while queue.any?
        current = queue.shift
        child_ids = MemoryRelation.where(to_entity_id: current, relation_type: type).pluck(:from_entity_id)
        child_ids.each do |child_id|
          next if ids.include?(child_id)

          ids.add(child_id)
          queue << child_id
        end
      end

      ids
    end

    def ambiguous_reverse_pair?(relation)
      symmetric?(relation.relation_type)
    end

    def ambiguous_multi_parent?(relation_type)
      !single_parent?(relation_type)
    end
  end
end
