# frozen_string_literal: true

# Composite merge evidence beyond cosine distance for dream-state compaction.
#
# Shared observations count only when {ObservationEvidence} finds them distinctive (long enough,
# not a "Key: value" line, held by at most 2 entities); boilerplate gives no merge credit.
class EntityMergeEvidence
  # Cosine-only is not enough for auto-merge; need lexical/shared evidence too.
  AUTO_SCORE = 10
  # Distance alone in the review band scores 4, so the floor sits above it: a review row needs
  # evidence beyond "the embeddings are near" (a distinctive shared observation, name or alias).
  REVIEW_SCORE = 6

  Match = Struct.new(:source, :target, :score, :distance, :reasons, keyword_init: true)

  class << self
    # Finds the best merge candidates for +entity+ (same type, higher id, within +review_distance+).
    #
    # @param entity [MemoryEntity] the source entity (must have an embedding, not a Project)
    # @param limit [Integer] max matches returned
    # @param review_distance [Float] cosine distance below which a pair is a candidate
    # @return [Array<Match>] matches scoring at least {REVIEW_SCORE}, best first
    def candidates_for(entity, limit: 3, review_distance: DreamStateCompactor::REVIEW_MERGE_DISTANCE)
      return [] if entity.embedding.blank?
      return [] if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      source_vector_sql = vector_sql_literal(entity)
      return [] unless source_vector_sql

      MemoryEntity
        .where.not(id: entity.id)
        .where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
        .where(entity_type: entity.entity_type)
        .with_embedding
        .where("id > ?", entity.id)
        .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, #{source_vector_sql}) AS vec_distance")
        .having("vec_distance < ?", review_distance)
        .order(Arel.sql("vec_distance ASC"))
        .limit(limit * 3)
        .to_a
        .map { |candidate| score_pair(entity, candidate, candidate[:vec_distance].to_f) }
        .select { |match| match.score >= REVIEW_SCORE }
        .sort_by { |match| [ -match.score, match.distance ] }
        .first(limit)
    end

    # Re-scores a live pair with the current rules, for re-checking an existing review row.
    # The distance comes from the stored embeddings; the pair must be same-type, non-Project
    # entities that both have an embedding.
    #
    # @param entity_a [MemoryEntity, nil]
    # @param entity_b [MemoryEntity, nil]
    # @param review_distance [Float] the distance bound a review candidate must stay under
    # @return [Boolean] true when score >= {REVIEW_SCORE} and distance < +review_distance+
    def qualifies?(entity_a, entity_b, review_distance: DreamStateCompactor::REVIEW_MERGE_DISTANCE)
      return false if entity_a.nil? || entity_b.nil? || entity_a.id == entity_b.id
      return false if entity_a.entity_type != entity_b.entity_type
      return false if entity_a.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      return false if entity_a.embedded_at.nil? || entity_b.embedded_at.nil?

      distance = pair_distance(entity_a, entity_b)
      return false if distance.nil? || distance >= review_distance

      score_pair(entity_a, entity_b, distance).score >= REVIEW_SCORE
    end

    # @param left [MemoryEntity]
    # @param right [MemoryEntity]
    # @return [MemoryEntity, MemoryEntity] the entity to merge away first, then the survivor
    def pick_survivor(left, right)
      left_score = canonical_score(left)
      right_score = canonical_score(right)

      # Prefer richer canonical entity; on ties keep the higher ID (historical dream-state convention).
      if left_score > right_score
        [ right, left ]
      elsif right_score > left_score
        [ left, right ]
      elsif left.id < right.id
        [ left, right ]
      else
        [ right, left ]
      end
    end

    private

    def score_pair(entity, candidate, distance)
      reasons = []
      score = 0

      if distance < DreamStateCompactor::AUTO_MERGE_DISTANCE
        score += 8
        reasons << "cosine_distance=#{distance.round(4)}"
      elsif distance < DreamStateCompactor::REVIEW_MERGE_DISTANCE
        score += 4
        reasons << "cosine_distance=#{distance.round(4)}"
      end

      if entity.name.to_s.casecmp?(candidate.name.to_s)
        score += 8
        reasons << "exact_name"
      elsif alias_match?(entity, candidate.name) || alias_match?(candidate, entity.name)
        score += 5
        reasons << "alias_name"
      end

      shared = shared_observation_count(entity, candidate)
      if shared.positive?
        score += [ shared * 2, 6 ].min
        reasons << "shared_observations=#{shared}"
      end

      Match.new(source: entity, target: candidate, score: score, distance: distance, reasons: reasons)
    end

    def canonical_score(entity)
      entity.memory_observations_count.to_i * 10 + entity.relations_from.count + entity.relations_to.count
    end

    def alias_match?(entity, name)
      return false if name.blank?

      aliases = entity.aliases.to_s.split(/[,|;]/).map(&:strip).reject(&:blank?)
      aliases.any? { |alias_name| alias_name.casecmp?(name.to_s) }
    end

    # Contents both entities hold as active observations and that are distinctive evidence.
    def shared_observation_count(left, right)
      left_contents = left.active_memory_observations.pluck(:content)
      return 0 if left_contents.empty?

      shared = right.active_memory_observations.where(content: left_contents).distinct.pluck(:content)
      ObservationEvidence.distinctive_contents(shared).size
    end

    # @return [Float, nil] cosine distance between the two stored embeddings
    def pair_distance(left, right)
      sql = "SELECT VEC_DISTANCE_COSINE(a.embedding, b.embedding) FROM memory_entities a, memory_entities b " \
            "WHERE a.id = #{left.id.to_i} AND b.id = #{right.id.to_i}"
      ActiveRecord::Base.connection.select_value(sql)&.to_f
    end

    def vector_sql_literal(entity)
      return if entity.embedding.blank?

      vector = entity.embedding.to_s.unpack("e*")
      return if vector.empty?

      text = QueryTokenizer.vector_literal(vector)
      quoted = ActiveRecord::Base.connection.quote(text)
      "VEC_FromText(#{quoted})"
    rescue StandardError
      nil
    end
  end
end
