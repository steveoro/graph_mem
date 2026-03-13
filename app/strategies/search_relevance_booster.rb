# frozen_string_literal: true

# Shared boost logic used by HybridSearchStrategy and SearchSubgraphTool
# to apply name matching, entity type priority, structural importance,
# and graduated context boosting.
#
# Constants are defined here and referenced by HybridSearchStrategy (which
# applies them to RRF scores) and by .rank_entity_ids (which applies them
# to a flat list of entity IDs for SearchSubgraphTool).
module SearchRelevanceBooster
  EXACT_NAME_MATCH_BONUS = 0.10
  NAME_PREFIX_MATCH_BONUS = 0.04

  ENTITY_TYPE_PRIORITY = {
    "Project" => 1.6,
    "ApplicationStack" => 1.3,
    "Framework" => 1.3,
    "BestPractice" => 1.3,
    "Workflow" => 1.3,
    "Feature" => 1.15,
    "Service" => 1.15,
    "Component" => 1.15,
    "Configuration" => 1.15
  }.freeze
  DEFAULT_TYPE_PRIORITY = 1.0

  STRUCTURAL_BOOST_FACTOR = 0.003

  CONTEXT_ROOT_BOOST = 0.04
  CONTEXT_CHILD_BOOST = 0.02

  # Rank a flat list of entity IDs by relevance using all boost signals.
  # Returns entity IDs sorted by descending score.
  # @param entity_ids [Array<Integer>]
  # @param query [String]
  # @param context_entity_ids [Array<Integer>, nil]
  # @return [Array<Integer>]
  def self.rank_entity_ids(entity_ids, query:, context_entity_ids: nil)
    return entity_ids if entity_ids.empty?

    entities = MemoryEntity.where(id: entity_ids).index_by(&:id)
    scores = entity_ids.each_with_object({}) { |id, h| h[id] = 0.0 }

    apply_name_match_boost(scores, entities, query)
    apply_type_priority(scores, entities)
    apply_structural_boost(scores, entity_ids)
    apply_graduated_context_boost(scores, context_entity_ids)

    scores.sort_by { |_id, score| -score }.map(&:first)
  end

  def self.apply_name_match_boost(scores, entities, query)
    return if query.blank?

    query_lower = query.to_s.strip.downcase

    scores.each_key do |id|
      entity = entities[id]
      next unless entity

      name_lower = entity.name.to_s.downcase

      if name_lower == query_lower
        scores[id] += EXACT_NAME_MATCH_BONUS
      elsif name_lower.start_with?(query_lower) || query_lower.start_with?(name_lower)
        scores[id] += NAME_PREFIX_MATCH_BONUS
      end
    end
  end

  def self.apply_type_priority(scores, entities)
    scores.each_key do |id|
      entity = entities[id]
      next unless entity

      multiplier = ENTITY_TYPE_PRIORITY[entity.entity_type] || DEFAULT_TYPE_PRIORITY
      base = [ scores[id], 0.01 ].max
      scores[id] = base * multiplier
    end
  end

  def self.apply_structural_boost(scores, entity_ids)
    return if entity_ids.empty?

    from_counts = MemoryRelation.where(from_entity_id: entity_ids).group(:from_entity_id).count
    to_counts = MemoryRelation.where(to_entity_id: entity_ids).group(:to_entity_id).count

    scores.each_key do |id|
      count = (from_counts[id] || 0) + (to_counts[id] || 0)
      scores[id] += Math.log2(1 + count) * STRUCTURAL_BOOST_FACTOR if count > 0
    end
  end

  def self.apply_graduated_context_boost(scores, context_entity_ids)
    return if context_entity_ids.blank?

    root_id = GraphMemContext.current_project_id
    context_set = context_entity_ids.to_set

    scores.each_key do |id|
      if id == root_id
        scores[id] += CONTEXT_ROOT_BOOST
      elsif context_set.include?(id)
        scores[id] += CONTEXT_CHILD_BOOST
      end
    end
  end
end
