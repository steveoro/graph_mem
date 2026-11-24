# frozen_string_literal: true

# Detects duplicate observations while importing data into an existing entity.
#
# Exact active-content matches are always considered duplicates. For altered
# content, the importer requires embeddings and compares the incoming text with
# every active observation already attached to the target entity.
#
# The membership lock is never held across a network call, so an import embeds its texts before it
# takes the lock (precompute!) and, under it, find_duplicate only looks vectors up: a text without
# one is matched exactly only, and fallback_warning sums those up in one line per import.
#
#   detector = ImportObservationDuplicateDetector.new
#   detector.precompute!([ "SynthWidget renders tiles." ])     # before the lock: one embedding call
#   detector.find_duplicate(entity: widget, content: "SynthWidget renders tiles.") # under it: none
#   detector.fallback_warning # => nil, or "Semantic observation de-duplication matched 2 fact(s) …"
class ImportObservationDuplicateDetector
  class UnavailableError < StandardError; end

  # The most distinct texts precompute! embeds: one embedding call each (EmbeddingService has no
  # batch call), made before the import takes the membership lock, while the operator waits (500
  # calls of about 50 ms each is under half a minute). The texts of a larger import beyond it are
  # matched exactly only, and the import's warning says so.
  MAX_PRECOMPUTED_TEXTS = 500

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
    @missing = {}
    @fallbacks = Hash.new(0)
  end

  # Embeds, before the caller takes the membership lock, the texts find_duplicate may compare
  # semantically under it. From then on find_duplicate makes no embedding call: a text with no
  # vector (not given here, beyond MAX_PRECOMPUTED_TEXTS, or the service failed) is matched exactly
  # only, and counted for fallback_warning. The first failed call ends the precompute (the service
  # is down: each later call would wait out its retries too). Without vector columns nothing is
  # embedded, and find_duplicate raises UnavailableError as before.
  # @param texts [Enumerable<String>] observation contents, as find_duplicate will get them
  # @return [Integer] how many texts got a vector
  def precompute!(texts)
    @precomputed = {}
    @missing = {}
    @fallbacks = Hash.new(0)
    @unavailable = nil
    distinct = texts.map(&:to_s).reject(&:blank?).uniq
    @distinct_count = distinct.size
    return 0 unless EmbeddingService.vector_enabled?

    distinct.each_with_index do |text, index|
      reason = if index >= MAX_PRECOMPUTED_TEXTS then :capped
      elsif @unavailable then :unavailable
      else precompute_vector(text)
      end
      @missing[text] = reason if reason
    end
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
  #   want of a precomputed vector, with how many and why; nil when none were
  def fallback_warning
    return nil if @fallbacks.empty?

    reasons = @fallbacks.map do |reason, count|
      case reason
      when :unavailable then "#{count} because the embedding service failed before the import (#{@unavailable})"
      when :capped then "#{count} beyond the first #{MAX_PRECOMPUTED_TEXTS} of #{@distinct_count} distinct texts embedded before the import"
      else "#{count} whose text was not embedded before the import"
      end
    end
    "Semantic observation de-duplication matched #{@fallbacks.values.sum} fact(s) exactly only: #{reasons.join('; ')}"
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
    @fallbacks[@missing.fetch(content, :not_precomputed)] += 1 unless vector
    vector
  end

  def embed!(content)
    @embedding_service.embed!(content)
  rescue StandardError => e
    raise UnavailableError, "Embedding service is unavailable: #{e.message}"
  end

  # @return [Symbol, nil] nil when the text got its vector, else why not
  def precompute_vector(text)
    vector = @embedding_service.embed!(text)
    if QueryTokenizer.vector_literal(vector).blank?
      @unavailable = "the embedding service returned no vector"
      return :unavailable
    end

    @precomputed[text] = vector
    nil
  rescue StandardError => e
    @unavailable = e.message
    :unavailable
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
