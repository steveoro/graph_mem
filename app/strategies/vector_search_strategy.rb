# frozen_string_literal: true

# Strategy for semantic vector search on MemoryEntity records.
# Uses MariaDB's native VECTOR search with cosine distance.
# Falls back gracefully when embeddings are unavailable.
class VectorSearchStrategy
  SearchResult = Struct.new(:entity, :distance, keyword_init: true)

  # Filter out vector results with cosine distance above this threshold.
  # Cosine distance range: 0 (identical) to 2 (opposite).
  # 0.85 removes weak semantic matches that introduce cross-project noise.
  MAX_COSINE_DISTANCE = 0.85

  def initialize(embedding_service: EmbeddingService.instance)
    @embedding_service = embedding_service
    @logger = Rails.logger
  end

  # Semantic search: embed the query, then find nearest entities.
  # @param query [String] Natural language query
  # @param limit [Integer] Max results
  # @param entity_type [String, nil] When provided, restrict results to this entity_type
  # @return [Array<SearchResult>] Ordered by cosine distance (smallest = most similar)
  def search(query, limit: 20, entity_type: nil)
    return [] unless EmbeddingService.vector_enabled?

    query_vector = @embedding_service.embed(query)
    return [] unless query_vector

    vector_sql = "[#{query_vector.join(',')}]"
    distance_sql = MemoryEntity.sanitize_sql_array(
      [ "VEC_DISTANCE_COSINE(embedding, VEC_FromText(?)) AS vec_distance", vector_sql ]
    )

    # Untyped searches must not filter `entity_type IS NULL` (matches nothing).
    entities = MemoryEntity.with_embedding
    entities = entities.where(entity_type: entity_type) if entity_type.present?
    entities = entities
      .select("memory_entities.*", Arel.sql(distance_sql))
      .having("vec_distance < ?", MAX_COSINE_DISTANCE)
      .order(Arel.sql("(vec_distance + 0) ASC"))
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
    distance_sql = MemoryObservation.sanitize_sql_array(
      [ "MIN(VEC_DISTANCE_COSINE(embedding, VEC_FromText(?))) AS vec_distance", vector_sql ]
    )

    # ORDER BY must repeat the distance expression: pluck rewrites SELECT,
    # so ordering on the `vec_distance` alias raises "Unknown column".
    order_sql = MemoryObservation.sanitize_sql_array(
      [ "MIN(VEC_DISTANCE_COSINE(embedding, VEC_FromText(?))) ASC", vector_sql ]
    )

    MemoryObservation
      .active
      .with_embedding
      .select(:memory_entity_id, Arel.sql(distance_sql))
      .group(:memory_entity_id)
      .order(Arel.sql(order_sql))
      .limit(limit)
      .pluck(:memory_entity_id)
  rescue StandardError => e
    @logger.error "VectorSearchStrategy#search_observations: #{e.message}"
    []
  end
end
