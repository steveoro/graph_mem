# frozen_string_literal: true

# Detects candidate contradictions between active observations.
#
# It uses the existing VECTOR embeddings on observations to find semantically
# similar statements and then applies a lightweight polarity check to flag
# pairs that likely conflict. Results are stored as a MaintenanceReport for
# operator review; no observations are modified automatically.
#
# Fact pertinence (1.78.0): with fact keywords on, two facts are paired only when their keyword
# paths say they're about the same thing (FactKeywords::Relatedness: a shared mention, or one
# mentions the other's entity). Two facts that mention no entity at all are paired only when very
# close (STRICT_MAX_DISTANCE). Pending paths are computed first. Before, any two close facts on an
# entity and its neighbours with one negative word were paired, unrelated or not. What the paths
# share is never stored in the row: it is recomputed where it's shown.
class ContradictionDetector
  DEFAULT_MAX_DISTANCE = 0.35
  # The most a pair of facts that mention no entity may differ (cosine distance) and still be paired.
  STRICT_MAX_DISTANCE = 0.15
  DEFAULT_MAX_RESULTS = 20
  # Review rows show this much of each observation; apply always re-reads the live rows.
  REVIEW_CONTENT_LIMIT = 300

  # Polarity markers are intentionally simple; they are heuristics, not NLP.
  NEGATIVE_MARKERS = %w[
    not no never none nobody nothing nowhere neither
    false incorrect wrong deprecated removed unsupported
    discontinued retired invalid
  ].freeze

  # `shared_keywords` / `strong`: what the two keyword paths share (nil with fact keywords off). In
  # memory only: never written to a review payload or a report.
  Result = Struct.new(:observation_id_1, :observation_id_2, :distance, :confidence, :shared_keywords, :strong, keyword_init: true)

  class << self
    # @param entity_id [Integer]
    # @param max_distance [Float] cosine distance threshold (smaller = closer)
    # @param max_results [Integer] max candidate pairs to return
    # @param persist [Boolean] whether to create a MaintenanceReport
    # @return [Array<Result>]
    def detect(entity_id, max_distance: DEFAULT_MAX_DISTANCE, max_results: DEFAULT_MAX_RESULTS, persist: true)
      return [] unless AppSettings.contradiction_detection_enabled?
      return [] unless EmbeddingService.vector_enabled?

      entity_ids = Array(entity_id) + related_entity_ids(entity_id)
      observations = load_observations(entity_ids)
      return [] if observations.length < 2

      pairs = find_contradiction_pairs(observations, max_distance, max_results)
      create_report(entity_id, pairs, max_distance) if persist && pairs.any?
      pairs
    end

    # The review row payload for a detected pair (UI-5a): both observations with their owners,
    # ids ordered low → high whatever the Result's order. One query for both observations.
    # @param result [Result]
    # @return [Hash, nil] nil when either observation is gone or no longer active
    def review_item(result)
      ids = [ result.observation_id_1, result.observation_id_2 ].map(&:to_i).sort
      rows = MemoryObservation.joins(:memory_entity).where(id: ids, status: MemoryObservation::ACTIVE_STATUS)
                              .pluck("memory_observations.id", "memory_observations.memory_entity_id",
                                     "memory_entities.name", "memory_observations.content").index_by(&:first)
      return nil unless rows.size == 2

      sides = ids.each_with_index.to_h do |id, index|
        _id, entity_id, name, content = rows[id]
        n = index + 1
        [ n, { "observation_id_#{n}": id, "entity_id_#{n}": entity_id, "entity_name_#{n}": name,
               "content_#{n}": content.to_s.truncate(REVIEW_CONTENT_LIMIT) } ]
      end
      # The shared keyword names stay off the payload (MCP review tools return it verbatim): the
      # review view and the no_shared_subject policy recompute them from the live paths.
      { kind: "contradiction", **sides[1], **sides[2], distance: result.distance, confidence: result.confidence,
        detected_at: Time.current.iso8601 }
    end

    # Whether two facts may form a contradiction pair, from their keyword paths (both computed):
    # related, or both without any mention and within STRICT_MAX_DISTANCE.
    #
    # @param first [MemoryObservation]
    # @param second [MemoryObservation]
    # @param distance [Float] their cosine distance
    # @return [FactKeywords::Relatedness::Comparison, nil] the comparison when pairable, else nil
    def pairable(first, second, distance)
      comparison = FactKeywords::Relatedness.compare(first, second)
      return comparison if comparison.related?

      comparison if comparison.subject == :unknown && distance.to_f <= STRICT_MAX_DISTANCE
    end

    # Whether the text has one of NEGATIVE_MARKERS as a word (FactSupersede uses it as a boost).
    #
    # @param text [String, nil]
    # @return [Boolean]
    def negative?(text)
      return false if text.blank?

      words = text.downcase.scan(/\b[\w']+\b/)
      NEGATIVE_MARKERS.any? { |marker| words.include?(marker) }
    end

    private

    def related_entity_ids(entity_id)
      from = MemoryRelation.where(from_entity_id: entity_id).pluck(:to_entity_id)
      to = MemoryRelation.where(to_entity_id: entity_id).pluck(:from_entity_id)
      (from + to).uniq
    end

    def load_observations(entity_ids)
      observations = MemoryObservation
        .active
        .where(memory_entity_id: entity_ids)
        .with_embedding
        .includes(:memory_entity)
        .to_a
      keyword_gate? ? FactKeywords.ensure!(observations) : observations
    end

    def keyword_gate?
      AppSettings.fact_keywords_enabled?
    end

    def find_contradiction_pairs(observations, max_distance, max_results)
      pairs = []
      entity_ids = observations.map(&:memory_entity_id).uniq
      by_id = observations.index_by(&:id)
      gate = keyword_gate?

      # Query each anchor observation against the set of candidate embeddings.
      # For small N (same entity + 1-hop) this is simple and correct; it can be
      # optimized later if contradiction detection is run on large subgraphs.
      observations.each do |anchor|
        next if anchor.embedding.blank?

        candidates = MemoryObservation
          .active
          .where(memory_entity_id: entity_ids)
          .where.not(id: anchor.id)
          .with_embedding
          .select(
            :id,
            :memory_entity_id,
            :content,
            Arel.sql("VEC_DISTANCE_COSINE(embedding, (SELECT o2.embedding FROM memory_observations o2 WHERE o2.id = #{anchor.id})) AS vec_distance")
          )
          .having("vec_distance < ?", max_distance)
          .order(Arel.sql("vec_distance ASC"))
          .limit(max_results)

        candidates.each do |candidate|
          next unless polarity_conflict?(anchor.content, candidate.content)

          distance = candidate[:vec_distance].to_f
          comparison = nil
          if gate
            other = by_id[candidate.id]
            comparison = other && FactKeywords::Relatedness.computed?(anchor, other) && pairable(anchor, other, distance)
            next unless comparison
          end

          pairs << Result.new(
            observation_id_1: anchor.id,
            observation_id_2: candidate.id,
            distance: distance,
            confidence: contradiction_confidence(distance),
            shared_keywords: comparison&.shared,
            strong: comparison&.strong
          )
        end
      end

      # De-duplicate symmetric pairs (a,b) and (b,a) by keeping the lower-id order.
      pairs.uniq { |p| [ p.observation_id_1, p.observation_id_2 ].sort }
           .sort_by { |p| -p.confidence }
           .first(max_results)
    end

    def polarity_conflict?(text1, text2)
      neg1 = negative?(text1)
      neg2 = negative?(text2)
      neg1 != neg2
    end

    def contradiction_confidence(distance)
      # High similarity (low distance) + polarity conflict = higher confidence.
      # Clamp at 0.99 to avoid false certainty.
      [ (1.0 - distance) * 1.1, 0.99 ].min.round(4)
    end

    def create_report(entity_id, pairs, max_distance)
      MaintenanceReport.create!(
        report_type: "contradictions",
        data: {
          entity_id: entity_id,
          max_distance: max_distance,
          candidate_count: pairs.length,
          candidates: pairs.map do |p|
            {
              observation_id_1: p.observation_id_1,
              observation_id_2: p.observation_id_2,
              distance: p.distance,
              confidence: p.confidence
            }
          end
        }
      )
    end
  end
end
