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

    # The service being down is still fatal to semantic de-duplication.
    ensure_embeddings_available!

    # Stored rows left unembedded — e.g. observations created by an import
    # whose deferred backfill has not run yet — cannot be compared
    # semantically. Degrade to the exact-content match above rather than
    # hard-failing the (re-)import; the backfill restores full dedup.
    if observations.missing_embedding.exists?
      Rails.logger.warn "ImportObservationDuplicateDetector: Entity '#{entity.name}' has " \
                        "unembedded observations; semantic de-duplication skipped (exact match only)"
      return Result.new(duplicate: false)
    end
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

  def ensure_embeddings_available!
    return if EmbeddingService.vector_enabled?

    raise UnavailableError, "Embedding vectors are unavailable; semantic observation de-duplication cannot run."
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

    # `(vec_distance + 0)` deliberately breaks the `ORDER BY VEC_DISTANCE_*(col,
    # const) LIMIT n` pattern that triggers MariaDB's ANN index scan. The ANN
    # path returns the globally nearest rows BEFORE applying the WHERE clause —
    # unembedded zero-vector placeholders rank as distance 0.0, consume the
    # LIMIT, and get filtered out by `with_embedding`, so the query can return
    # no row at all on a relation that has embedded observations. Ordering on
    # the computed expression keeps exact, filtered ordering (the entity-scoped
    # set is small, so the ANN index buys nothing here).
    observations
      .with_embedding
      .select(:id, Arel.sql(distance_sql))
      .order(Arel.sql("(vec_distance + 0) ASC"))
      .first
  rescue ActiveRecord::StatementInvalid => e
    raise UnavailableError, "Embedding vector comparison failed: #{e.message}"
  end
end
