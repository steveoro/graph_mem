# frozen_string_literal: true

# Composite merge evidence beyond cosine distance for dream-state compaction.
class EntityMergeEvidence
  # Cosine-only is not enough for auto-merge; need lexical/shared evidence too.
  AUTO_SCORE = 10
  REVIEW_SCORE = 4

  Match = Struct.new(:source, :target, :score, :distance, :reasons, keyword_init: true)

  class << self
    def candidates_for(entity, limit: 3, review_distance: DreamStateCompactor::REVIEW_MERGE_DISTANCE)
      return [] if entity.embedding.blank?
      return [] if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      source_vector_sql = vector_sql_literal(entity)
      return [] unless source_vector_sql

      MemoryEntity
        .where.not(id: entity.id)
        .where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
        .where(entity_type: entity.entity_type)
        .where.not(embedding: nil)
        .where("id > ?", entity.id)
        .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, #{source_vector_sql}) AS vec_distance")
        .having("vec_distance < ?", review_distance)
        .order(Arel.sql("vec_distance ASC"))
        .limit(limit * 3)
        .to_a
        .map { |candidate| score_pair(entity, candidate) }
        .select { |match| match.score >= REVIEW_SCORE }
        .sort_by { |match| [ -match.score, match.distance ] }
        .first(limit)
    end

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

    def score_pair(entity, candidate)
      distance = candidate[:vec_distance].to_f
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

    def shared_observation_count(left, right)
      left_contents = left.active_memory_observations.pluck(:content)
      return 0 if left_contents.empty?

      right.active_memory_observations.where(content: left_contents).count
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
