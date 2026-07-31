# frozen_string_literal: true

# Detects duplicate observations while importing data into an existing entity.
#
# Exact active-content matches are always considered duplicates. For altered
# content, the importer requires embeddings and compares the incoming text with
# every active observation already attached to the target entity.
class ImportObservationDuplicateDetector
  class UnavailableError < StandardError; end

  Result = Struct.new(
    :duplicate,
    :observation,
    :distance,
    :exact_match,
    keyword_init: true
  )

  def initialize(embedding_service: EmbeddingService.instance, threshold: AppSettings.import_observation_duplicate_max_distance)
    @embedding_service = embedding_service
    @threshold = threshold.to_f
  end

  # @param entity [MemoryEntity] Target entity for the imported observation
  # @param content [String] Imported observation content
  # @return [Result]
  # @raise [UnavailableError] when semantic comparison is required but cannot run
  def find_duplicate(entity:, content:)
    normalized_content = content.to_s
    return Result.new(duplicate: false) if normalized_content.blank?

    observations = MemoryObservation.active.where(memory_entity_id: entity.id)
    exact_match = observations.find_by(content: normalized_content)
    return Result.new(duplicate: true, observation: exact_match, distance: 0.0, exact_match: true) if exact_match
    return Result.new(duplicate: false) unless observations.exists?

    ensure_embeddings_available!(observations, entity)
    incoming_vector = embed!(normalized_content)
    closest = nearest_observation(observations, incoming_vector)
    return Result.new(duplicate: false) unless closest

    distance = closest[:vec_distance].to_f
    Result.new(
      duplicate: distance <= @threshold,
      observation: closest,
      distance: distance,
      exact_match: false
    )
  end

  private

  def ensure_embeddings_available!(observations, entity)
    unless EmbeddingService.vector_enabled?
      raise UnavailableError, "Embedding vectors are unavailable; semantic observation de-duplication cannot run."
    end

    return unless observations.where(embedding: nil).exists?

    raise UnavailableError,
          "Entity '#{entity.name}' has observations without embeddings; run embedding backfill before importing."
  end

  def embed!(content)
    @embedding_service.embed!(content)
  rescue StandardError => e
    raise UnavailableError, "Embedding service is unavailable: #{e.message}"
  end

  def nearest_observation(observations, incoming_vector)
    vector_sql = QueryTokenizer.vector_literal(incoming_vector)
    raise UnavailableError, "Embedding service returned an empty vector." if vector_sql.blank?

    distance_sql = MemoryObservation.sanitize_sql_array(
      [ "VEC_DISTANCE_COSINE(embedding, VEC_FromText(?)) AS vec_distance", vector_sql ]
    )

    observations
      .where.not(embedding: nil)
      .select(:id, Arel.sql(distance_sql))
      .order(Arel.sql("vec_distance ASC"))
      .first
  rescue ActiveRecord::StatementInvalid => e
    raise UnavailableError, "Embedding vector comparison failed: #{e.message}"
  end
end
