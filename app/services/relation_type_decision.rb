# frozen_string_literal: true

# The operator's answer for an unmapped relation type (R1a, plan item 4), as one row of
# `relation_type_mappings`; no relation is changed here (the next RelationTypeSweep applies it):
#
# - **map**: `variant` = the folded type, `canonical_type` = a GraphVocabulary type;
# - **accept** (a known novel type): a self-mapping, `variant` = `canonical_type` = the folded
#   type, so MemoryRelation.mapped_relation_type answers it (the type leaves the unmapped list and
#   graph_write stops hinting for it) and a sweep stores it folded;
# - **remove**: deletes a row (mapped, accepted or seeded alike), so the type is unmapped again.
#
# Each one resets the canonicalize cache of this process; other processes follow within
# RelationTypeMapping::CANONICALIZE_TTL, and a sweep resets its own first.
#
#   RelationTypeDecision.map("Synth Link Kind", "depends_on")
#   # => #<data Result ok=true, key=:mapped, type="synth_link_kind", canonical_type="depends_on", relations=3>
class RelationTypeDecision
  # @!attribute ok [Boolean]
  # @!attribute key [Symbol] what happened (:mapped, :mapped_part_of, :accepted, :removed) or why not (:blank,
  #   :too_long, :canonical, :already_mapped, :not_canonical, :not_found)
  # @!attribute type [String, nil] the folded type (the removed row's variant for a removal)
  # @!attribute canonical_type [String, nil]
  # @!attribute relations [Integer] relations stored with a spelling of the type
  Result = Data.define(:ok, :key, :type, :canonical_type, :relations)

  MAX_LENGTH = 255

  class << self
    # @param raw_type [String] a stored type (any spelling)
    # @param canonical_type [String] one of GraphVocabulary::RELATION_TYPES
    # @return [Result]
    def map(raw_type, canonical_type)
      type = MemoryRelation.fold_relation_type(raw_type)
      canonical = canonical_type.to_s
      refusal = refusal_for(type) || (:not_canonical unless GraphVocabulary::RELATION_TYPES.include?(canonical))
      return result(false, refusal, type, canonical) if refusal

      record(type, canonical, canonical == RelationTypeSweep::PART_OF ? :mapped_part_of : :mapped)
    end

    # @param raw_type [String] a stored type (any spelling)
    # @return [Result]
    def accept(raw_type)
      type = MemoryRelation.fold_relation_type(raw_type)
      refusal = refusal_for(type)
      return result(false, refusal, type, nil) if refusal

      record(type, type, :accepted)
    end

    # @param id [Integer, String] a RelationTypeMapping id
    # @return [Result]
    def remove(id)
      mapping = RelationTypeMapping.find_by(id: id)
      return result(false, :not_found, nil, nil) unless mapping

      mapping.destroy!
      RelationTypeMapping.reset_canonicalize_cache!
      log(:removed, mapping.variant, mapping.canonical_type)
      result(true, :removed, mapping.variant, mapping.canonical_type)
    end

    # @param mapping [RelationTypeMapping]
    # @return [Symbol] :accepted (a novel type mapped to itself), :canonical (a vocabulary type's
    #   own row, as a seed writes it) or :mapped
    def kind(mapping)
      own = MemoryRelation.fold_relation_type(mapping.variant) == mapping.canonical_type
      return :mapped unless own

      GraphVocabulary::RELATION_TYPES.include?(mapping.canonical_type) ? :canonical : :accepted
    end

    private

    # Reads the table afresh: another process may have changed it within the cache's TTL.
    def refusal_for(type)
      return :blank if type.blank?
      return :too_long if type.length > MAX_LENGTH
      return :canonical if GraphVocabulary::RELATION_TYPES.include?(type)

      RelationTypeMapping.reset_canonicalize_cache!
      :already_mapped if MemoryRelation.mapped_relation_type(type)
    end

    def record(type, canonical, key)
      RelationTypeMapping.create!(variant: type, canonical_type: canonical)
      RelationTypeMapping.reset_canonicalize_cache!
      log(key, type, canonical)
      result(true, key, type, canonical)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      result(false, :already_mapped, type, canonical)
    end

    def result(ok, key, type, canonical)
      Result.new(ok: ok, key: key, type: type, canonical_type: canonical,
                 relations: type.present? ? UnmappedRelationTypes.relations_for(type) : 0)
    end

    def log(key, type, canonical)
      Rails.logger.info("[RelationTypeDecision] #{key} #{type} -> #{canonical} by #{Current.actor || 'unknown'}")
    end
  end
end
