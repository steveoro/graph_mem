# frozen_string_literal: true

# Combines text-based (EntitySearchStrategy) and vector-based (VectorSearchStrategy)
# search results using weighted Reciprocal Rank Fusion (RRF), then applies
# post-fusion boosts for name matching, entity type priority, structural
# importance, and graduated context boosting.
class HybridSearchStrategy
  RRF_K = 60

  SearchResult = Struct.new(:entity, :score, :matched_fields, keyword_init: true) do
    def to_h
      {
        entity_id: entity.id,
        name: entity.name,
        entity_type: entity.entity_type,
        description: entity.description,
        aliases: entity.aliases,
        memory_observations_count: entity.memory_observations_count,
        created_at: entity.created_at.iso8601,
        updated_at: entity.updated_at.iso8601,
        relevance_score: score.round(4),
        matched_fields: matched_fields
      }
    end
  end

  def initialize
    @text_strategy = EntitySearchStrategy.new
    @vector_strategy = VectorSearchStrategy.new
    @logger = Rails.logger
  end

  # @param query [String]
  # @param limit [Integer]
  # @param semantic [Boolean] When false, skip vector search entirely
  # @param context_entity_ids [Array<Integer>, nil] Entity IDs to boost (from GraphMemContext)
  # @return [Array<SearchResult>]
  def search(query, limit: 50, semantic: true, context_entity_ids: nil)
    @query = query.to_s.strip

    text_results = @text_strategy.search(query, limit: limit * 2)

    vector_results = if semantic
      @vector_strategy.search(query, limit: limit * 2)
    else
      []
    end

    scores, entities, matched = build_score_maps(text_results, vector_results)
    apply_relevance_boosts(scores, entities, context_entity_ids)

    scores
      .sort_by { |_id, score| -score }
      .first(limit)
      .map do |id, score|
        SearchResult.new(
          entity: entities[id],
          score: score,
          matched_fields: matched[id]
        )
      end
  end

  private

  # Build initial score maps from text and vector results using weighted RRF.
  # Text scores are preserved as weights on the RRF contribution so that
  # well-differentiated text rankings survive the fusion.
  def build_score_maps(text_results, vector_results)
    scores = Hash.new(0.0)
    entities = {}
    matched = Hash.new { |h, k| h[k] = [] }

    max_text_score = text_results.map(&:score).max || 1.0
    max_text_score = [ max_text_score, 1.0 ].max

    text_results.each_with_index do |result, rank|
      id = result.entity.id
      normalized = result.score / max_text_score
      scores[id] += (1.0 / (RRF_K + rank + 1)) * (1.0 + normalized)
      entities[id] = result.entity
      matched[id] = result.matched_fields
    end

    vector_results.each_with_index do |result, rank|
      id = result.entity.id
      scores[id] += 1.0 / (RRF_K + rank + 1)
      entities[id] ||= result.entity
      matched[id] |= [ "semantic" ]
    end

    [ scores, entities, matched ]
  end

  def apply_relevance_boosts(scores, entities, context_entity_ids)
    return if scores.empty?

    apply_name_match_boost(scores, entities)
    apply_type_priority(scores, entities)
    apply_structural_boost(scores, entities)
    apply_graduated_context_boost(scores, context_entity_ids)
  end

  def apply_name_match_boost(scores, entities)
    return if @query.blank?

    query_lower = @query.downcase

    scores.each_key do |id|
      entity = entities[id]
      next unless entity

      name_lower = entity.name.to_s.downcase

      if name_lower == query_lower
        scores[id] += SearchRelevanceBooster::EXACT_NAME_MATCH_BONUS
      elsif name_lower.start_with?(query_lower) || query_lower.start_with?(name_lower)
        scores[id] += SearchRelevanceBooster::NAME_PREFIX_MATCH_BONUS
      end
    end
  end

  def apply_type_priority(scores, entities)
    scores.each_key do |id|
      entity = entities[id]
      next unless entity

      multiplier = SearchRelevanceBooster::ENTITY_TYPE_PRIORITY[entity.entity_type] ||
                   SearchRelevanceBooster::DEFAULT_TYPE_PRIORITY
      scores[id] *= multiplier
    end
  end

  def apply_structural_boost(scores, entities)
    entity_ids = scores.keys
    return if entity_ids.empty?

    from_counts = MemoryRelation.where(from_entity_id: entity_ids).group(:from_entity_id).count
    to_counts = MemoryRelation.where(to_entity_id: entity_ids).group(:to_entity_id).count

    scores.each_key do |id|
      count = (from_counts[id] || 0) + (to_counts[id] || 0)
      scores[id] += Math.log2(1 + count) * SearchRelevanceBooster::STRUCTURAL_BOOST_FACTOR if count > 0
    end
  end

  def apply_graduated_context_boost(scores, context_entity_ids)
    return if context_entity_ids.blank?

    root_id = GraphMemContext.current_project_id
    context_set = context_entity_ids.to_set

    scores.each_key do |id|
      if id == root_id
        scores[id] += SearchRelevanceBooster::CONTEXT_ROOT_BOOST
      elsif context_set.include?(id)
        scores[id] += SearchRelevanceBooster::CONTEXT_CHILD_BOOST
      end
    end
  end
end
