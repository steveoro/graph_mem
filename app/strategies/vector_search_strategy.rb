# frozen_string_literal: true

# Strategy for semantic vector search on MemoryEntity records.
# Uses MariaDB's native VECTOR search with cosine distance.
# Falls back gracefully when embeddings are unavailable.
class VectorSearchStrategy
  SearchResult = Struct.new(:entity, :distance, keyword_init: true)

  def initialize(embedding_service: EmbeddingService.instance)
    @embedding_service = embedding_service
    @logger = Rails.logger
  end

  # Semantic search: embed the query, then find nearest entities.
  # @param query [String] Natural language query
  # @param limit [Integer] Max results
  # @return [Array<SearchResult>] Ordered by cosine distance (smallest = most similar)
  def search(query, limit: 20)
    return [] unless EmbeddingService.vector_enabled?

    query_vector = @embedding_service.embed(query)
    return [] unless query_vector

    vector_sql = "[#{query_vector.join(',')}]"

    entities = MemoryEntity
      .where.not(embedding: nil)
      .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, VEC_FromText('#{vector_sql}')) AS vec_distance")
      .order(Arel.sql("vec_distance ASC"))
      .limit(limit)

    entities.map { |e| SearchResult.new(entity: e, distance: e[:vec_distance].to_f) }
  rescue StandardError => e
    @logger.error "VectorSearchStrategy: #{e.message}"
    []
  end

  # Search observations semantically.
  # @return [Array<Integer>] Entity IDs whose observations match
  def search_observations(query, limit: 50)
    return [] unless EmbeddingService.vector_enabled?

    query_vector = @embedding_service.embed(query)
    return [] unless query_vector

    vector_sql = "[#{query_vector.join(',')}]"

    MemoryObservation
      .where.not(embedding: nil)
      .select("memory_entity_id, MIN(VEC_DISTANCE_COSINE(embedding, VEC_FromText('#{vector_sql}'))) AS vec_distance")
      .group(:memory_entity_id)
      .order(Arel.sql("vec_distance ASC"))
      .limit(limit)
      .pluck(:memory_entity_id)
  rescue StandardError => e
    @logger.error "VectorSearchStrategy#search_observations: #{e.message}"
    []
  end
end
