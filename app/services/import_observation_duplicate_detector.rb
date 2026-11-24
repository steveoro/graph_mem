# frozen_string_literal: true

# Detects duplicate observations while importing data into an existing entity.
#
# Exact active-content matches are always considered duplicates. For altered
# content, the importer requires embeddings and compares the incoming text with
# every active observation already attached to the target entity.
#
# The membership lock is never held across a network call, so an import embeds its texts before it
# takes the lock (precompute!, which raises UnavailableError when the service fails, so the import
# stops before writing anything) and, under it, find_duplicate only looks vectors up: a text without
# one (the import's pre-read missed it) is matched exactly only, and fallback_warning sums those up
# in one line per import.
#
#   detector = ImportObservationDuplicateDetector.new
#   detector.precompute!([ "SynthWidget renders tiles." ])     # before the lock: one embedding call
#   detector.find_duplicate(entity: widget, content: "SynthWidget renders tiles.") # under it: none
#   detector.fallback_warning # => nil, or "Semantic observation de-duplication matched 1 fact(s) …"
class ImportObservationDuplicateDetector
  class UnavailableError < StandardError; end

  Result = Struct.new(
    :duplicate,
    :observation,
    :distance,
    :exact_match,
    keyword_init: true
  )

  # @param embedding_service [EmbeddingService]
  # @param threshold [Float] the largest cosine distance that still counts as a duplicate
  # @param only_embedded [Boolean] compare against the entity's embedded observations only, instead
  #   of skipping the semantic check when one is still unembedded (1.76.0: project scans, whose Rails
  #   code map facts wait for a deferred backfill)
  def initialize(embedding_service: EmbeddingService.instance, threshold: AppSettings.import_observation_duplicate_max_distance,
                 only_embedded: false)
    @embedding_service = embedding_service
    @threshold = threshold.to_f
    @only_embedded = only_embedded
    @precomputed = nil
    @fallbacks = 0
  end

  # Embeds, before the caller takes the membership lock, every text find_duplicate may compare
  # semantically under it, one embedding call per distinct text (EmbeddingService has no batch
  # call). From then on find_duplicate makes no embedding call: a text with no vector (one the
  # caller didn't pass: its pre-read raced an entity or a fact that changed before the lock) is
  # matched exactly only, and counted for fallback_warning. Without vector columns nothing is
  # embedded, and find_duplicate raises UnavailableError as before.
  # @param texts [Enumerable<String>] observation contents, as find_duplicate will get them
  # @return [Integer] how many texts got a vector
  # @raise [UnavailableError] at the first failed call ("Embedding service is unavailable: …", the
  #   error find_duplicate's own call raised before), so the caller stops before it writes anything
  def precompute!(texts)
    @precomputed = {}
    @fallbacks = 0
    return 0 unless EmbeddingService.vector_enabled?

    texts.map(&:to_s).reject(&:blank?).uniq.each { |text| @precomputed[text] = precompute_vector(text) }
    @precomputed.size
  end

  # Whether find_duplicate compares an entity's facts semantically, from their embedded_at stamps:
  # all of them embedded, or (only_embedded) at least one. The SQL in find_duplicate applies the
  # same rule; an import's pre-read (ImportExecutionStrategy::DuplicateVectors) uses this one.
  # @param stamps [Array<Time, nil>] the embedded_at of the entity's active facts
  # @return [Boolean]
  def compares_semantically?(stamps)
    return false if stamps.empty?

    @only_embedded ? stamps.any?(&:present?) : stamps.all?(&:present?)
  end

  # @return [String, nil] one line for the import's log when facts were matched exactly only for
  #   want of a precomputed vector, with how many; nil when none were
  def fallback_warning
    return nil if @fallbacks.zero?

    "Semantic observation de-duplication matched #{@fallbacks} fact(s) exactly only: " \
      "#{@fallbacks} whose text was not embedded before the import"
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
    return Result.new(duplicate: false) if @only_embedded && !observations.with_embedding.exists?
    if !@only_embedded && observations.missing_embedding.exists?
      Rails.logger.warn "ImportObservationDuplicateDetector: Entity '#{entity.name}' has " \
                        "unembedded observations; semantic de-duplication skipped (exact match only)"
      return Result.new(duplicate: false)
    end
    incoming_vector = query_vector(normalized_content)
    return Result.new(duplicate: false) unless incoming_vector

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

  # After precompute!, and always under the membership lock, only a precomputed vector is used: the
  # lock is never held across a network call. nil: match exactly only.
  def query_vector(content)
    return embed!(content) unless @precomputed || ProjectMembership.membership_lock_held?

    vector = @precomputed&.[](content)
    @fallbacks += 1 unless vector
    vector
  end

  def embed!(content)
    @embedding_service.embed!(content)
  rescue StandardError => e
    raise UnavailableError, "Embedding service is unavailable: #{e.message}"
  end

  # The errors find_duplicate raised when it embedded under the lock: a failed call
  # (embed!) or an empty vector (nearest_observation).
  def precompute_vector(text)
    vector = embed!(text)
    raise UnavailableError, "Embedding service returned an empty vector." if QueryTokenizer.vector_literal(vector).blank?

    vector
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
