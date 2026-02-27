# frozen_string_literal: true

# Combines text-based (EntitySearchStrategy) and vector-based (VectorSearchStrategy)
# search results using Reciprocal Rank Fusion (RRF).
class HybridSearchStrategy
  # RRF constant -- higher values smooth out rank differences
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
  # @return [Array<SearchResult>]
  def search(query, limit: 50, semantic: true)
    text_results = @text_strategy.search(query, limit: limit * 2)

    vector_results = if semantic
      @vector_strategy.search(query, limit: limit * 2)
    else
      []
    end

    if vector_results.empty?
      return text_results.first(limit)
    end

    fuse(text_results, vector_results, limit)
  end

  private

  def fuse(text_results, vector_results, limit)
    scores = Hash.new(0.0)
    entities = {}
    matched_fields = Hash.new { |h, k| h[k] = [] }

    text_results.each_with_index do |result, rank|
      id = result.entity.id
      scores[id] += 1.0 / (RRF_K + rank + 1)
      entities[id] = result.entity
      matched_fields[id] = result.matched_fields
    end

    vector_results.each_with_index do |result, rank|
      id = result.entity.id
      scores[id] += 1.0 / (RRF_K + rank + 1)
      entities[id] ||= result.entity
      matched_fields[id] |= [ "semantic" ]
    end

    scores
      .sort_by { |_id, score| -score }
      .first(limit)
      .map do |id, score|
        SearchResult.new(
          entity: entities[id],
          score: score,
          matched_fields: matched_fields[id]
        )
      end
  end
end
