# frozen_string_literal: true

# Scores how well an observation matches a summarization query using token
# overlap and optional vector similarity against the query embedding.
# Only embedded observations (`embedded_at` set) get a vector score; the others
# are scored on their tokens alone.
#
#   ranker = ObservationRelevanceRanker.new("alpha service latency")
#   ranker.score_batch(observations) # => [0.6, 0.5, ...]
class ObservationRelevanceRanker
  TOKEN_WEIGHT = 0.6
  VECTOR_WEIGHT = 0.4

  # @param query [String] the query to score against (blank: token score 0, no vector)
  # @param embedding_service [EmbeddingService] embeds the query when vectors are enabled
  def initialize(query, embedding_service: EmbeddingService.instance)
    @query = query.to_s.strip
    @tokens = tokenize(@query)
    @embedding_service = embedding_service
    @query_vector = load_query_vector
  end

  # @param observation [MemoryObservation]
  # @return [Float] the relevance score, 0.0 to 1.0
  def score(observation)
    scores = score_batch([ observation ])
    scores.first
  end

  # @param observations [Array<MemoryObservation>]
  # @return [Array<Float>] one relevance score (0.0 to 1.0) per observation, in order
  def score_batch(observations)
    observations = Array(observations)
    token_scores = observations.map { |observation| token_overlap(observation.content) }
    vector_scores = batch_vector_similarity(observations)

    observations.each_index.map do |index|
      combine_scores(token_scores[index], vector_scores[index])
    end
  end

  private

  def load_query_vector
    return nil if @query.blank?
    return nil unless EmbeddingService.vector_enabled?

    @embedding_service.embed(@query)
  rescue StandardError
    nil
  end

  def tokenize(text)
    QueryTokenizer.tokenize(text)
  end

  def token_overlap(content)
    QueryTokenizer.overlap_score(@tokens, content)
  end

  # nil for an unembedded observation: its column may hold the zero-vector placeholder, whose
  # NaN distance reads as 0.0 and would score 1.0. The stamp is checked on the loaded record and
  # again on the row (`with_embedding`).
  def batch_vector_similarity(observations)
    return observations.map { nil } if @query_vector.blank?

    ids = observations.filter_map { |observation| observation.id if observation.embedded_at.present? }
    return observations.map { nil } if ids.empty?

    vector_sql = QueryTokenizer.vector_literal(@query_vector)
    return observations.map { nil } if vector_sql.blank?
    distances = MemoryObservation
      .where(id: ids)
      .with_embedding
      .select(
        :id,
        Arel.sql("VEC_DISTANCE_COSINE(embedding, VEC_FromText('#{vector_sql}')) AS vec_distance")
      )
      .index_by(&:id)

    observations.map do |observation|
      next nil unless observation.embedded_at.present?

      distance = distances[observation.id]&.vec_distance
      next nil if distance.nil?

      [ 1.0 - distance.to_f, 0.0 ].max
    end
  rescue StandardError
    observations.map { nil }
  end

  def combine_scores(token_score, vector_score)
    return token_score if vector_score.nil?

    (token_score * TOKEN_WEIGHT) + (vector_score * VECTOR_WEIGHT)
  end
end
