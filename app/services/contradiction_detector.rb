# frozen_string_literal: true

# Detects candidate contradictions between active observations.
#
# It uses the existing VECTOR embeddings on observations to find semantically
# similar statements and then applies a lightweight polarity check to flag
# pairs that likely conflict. Results are stored as a MaintenanceReport for
# operator review; no observations are modified automatically.
class ContradictionDetector
  DEFAULT_MAX_DISTANCE = 0.35
  DEFAULT_MAX_RESULTS = 20

  # Polarity markers are intentionally simple; they are heuristics, not NLP.
  NEGATIVE_MARKERS = %w[
    not no never none nobody nothing nowhere neither
    false incorrect wrong deprecated removed unsupported
    discontinued retired invalid
  ].freeze

  Result = Struct.new(:observation_id_1, :observation_id_2, :distance, :confidence, keyword_init: true)

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

    private

    def related_entity_ids(entity_id)
      from = MemoryRelation.where(from_entity_id: entity_id).pluck(:to_entity_id)
      to = MemoryRelation.where(to_entity_id: entity_id).pluck(:from_entity_id)
      (from + to).uniq
    end

    def load_observations(entity_ids)
      MemoryObservation
        .active
        .where(memory_entity_id: entity_ids)
        .where.not(embedding: nil)
        .to_a
    end

    def find_contradiction_pairs(observations, max_distance, max_results)
      pairs = []
      entity_ids = observations.map(&:memory_entity_id).uniq

      # Query each anchor observation against the set of candidate embeddings.
      # For small N (same entity + 1-hop) this is simple and correct; it can be
      # optimized later if contradiction detection is run on large subgraphs.
      observations.each do |anchor|
        next if anchor.embedding.blank?

        candidates = MemoryObservation
          .active
          .where(memory_entity_id: entity_ids)
          .where.not(id: anchor.id)
          .where.not(embedding: nil)
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

          pairs << Result.new(
            observation_id_1: anchor.id,
            observation_id_2: candidate.id,
            distance: candidate[:vec_distance].to_f,
            confidence: contradiction_confidence(candidate[:vec_distance].to_f)
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

    def negative?(text)
      return false if text.blank?

      words = text.downcase.scan(/\b[\w']+\b/)
      NEGATIVE_MARKERS.any? { |marker| words.include?(marker) }
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
