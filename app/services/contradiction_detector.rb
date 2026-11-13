# frozen_string_literal: true

# Detects candidate contradictions between active observations.
#
# It uses the existing VECTOR embeddings on observations to find semantically
# similar statements and then applies a lightweight polarity check to flag
# pairs that likely conflict. Results are stored as a MaintenanceReport for
# operator review; no observations are modified automatically.
#
# Fact pertinence (1.78.0): with fact keywords on, two facts are paired only when their keyword
# paths say they're about the same subject (FactKeywords::Relatedness). Pending paths are computed
# first. What the paths share is never stored in the row: it is recomputed where it's shown.
#
# Review queue noise (1.85.0), on top of that:
# - two dated events (both start with "[YYYY-MM-DD]") never pair: two events don't contradict;
# - a shared mention of another project (its root, or an entity it owns) doesn't make the same
#   subject; facts of two different Project roots are unrelated (Relatedness);
# - the `:unknown` fallback (two facts that mention no entity, within STRICT_MAX_DISTANCE) no longer
#   makes a contradiction pair (Steve, decision 2): .scan returns those pairs as `fallback`, and the
#   stale scan hands them to FactSupersede::ContradictionFallback (newer fact against older).
#
#   scan = ContradictionDetector.scan(entity.id, persist: false)
#   scan.pairs    # => [#<struct Result observation_id_1=12, observation_id_2=15, …>] (contradiction rows)
#   scan.fallback # => [#<struct Result …>] (close facts with no subject to tell: FactSupersede's)
#   ContradictionDetector.still_pairable?(first, second) # => false once a rule above excludes them
class ContradictionDetector
  DEFAULT_MAX_DISTANCE = 0.35
  # The most a pair of facts that mention no entity may differ (cosine distance) and still be handed
  # over to the fallback (FactSupersede::ContradictionFallback).
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

  # A dated event: the fact starts with a "[YYYY-MM-DD]" stamp (a time after the date allowed).
  DATED_EVENT = /\A\s*\[\d{4}-\d{2}-\d{2}(?:[ T][^\]]*)?\]/

  # @!attribute pairs [Array<Result>] contradiction pairs (review rows, the report, the tool's answer)
  # @!attribute fallback [Array<Result>] the `:unknown` fallback pairs (1.85.0): never contradiction
  #   rows; the stale scan routes them through FactSupersede::ContradictionFallback
  Scan = Data.define(:pairs, :fallback)

  class << self
    # @param entity_id [Integer]
    # @param max_distance [Float] cosine distance threshold (smaller = closer)
    # @param max_results [Integer] max candidate pairs to return
    # @param persist [Boolean] whether to create a MaintenanceReport
    # @return [Array<Result>] the contradiction pairs only (see .scan for the fallback ones)
    def detect(entity_id, max_distance: DEFAULT_MAX_DISTANCE, max_results: DEFAULT_MAX_RESULTS, persist: true)
      scan(entity_id, max_distance: max_distance, max_results: max_results, persist: persist).pairs
    end

    # .detect plus the `:unknown` fallback pairs (1.85.0). The report lists the contradiction pairs only.
    #
    # @param entity_id [Integer]
    # @param max_distance [Float] cosine distance threshold (smaller = closer)
    # @param max_results [Integer] max pairs of each list
    # @param persist [Boolean] whether to create a MaintenanceReport (when there are contradiction pairs)
    # @return [Scan]
    def scan(entity_id, max_distance: DEFAULT_MAX_DISTANCE, max_results: DEFAULT_MAX_RESULTS, persist: true)
      none = Scan.new(pairs: [], fallback: [])
      return none unless AppSettings.contradiction_detection_enabled? && EmbeddingService.vector_enabled?

      entity_ids = Array(entity_id) + related_entity_ids(entity_id)
      observations = load_observations(entity_ids)
      return none if observations.length < 2

      found = find_contradiction_pairs(observations, max_distance, max_results)
      create_report(entity_id, found.pairs, max_distance) if persist && found.pairs.any?
      found
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

    # Whether two facts may form a contradiction pair, from their keyword paths (both computed): about
    # the same subject (1.82.0; applying a contradiction obsoletes one side, so being related isn't
    # enough), counting no mention of another project (1.85.0; see .foreign_only? for where such a pair goes), and
    # not two dated events. Two facts
    # that mention no entity never pair since 1.85.0 (see .fallback?).
    #
    # @param first [MemoryObservation]
    # @param second [MemoryObservation]
    # @return [FactKeywords::Relatedness::Comparison, nil] the comparison when pairable (without the
    #   other projects' mentions), else nil
    def pairable(first, second)
      return nil if dated_events?(first.content, second.content)

      comparison = FactKeywords::Relatedness.compare(first, second)
      return nil unless comparison.same_subject

      foreign = foreign_mentions(first, second)
      return comparison if foreign.empty?

      own = FactKeywords::Relatedness.compare(first, second, ignore: foreign)
      own if own.same_subject
    end

    # Whether a pair .pairable refuses goes to FactSupersede instead (1.85.0), unless the two are dated
    # events:
    # - an `:unknown` pair: neither fact mentions an entity, the paths can't tell
    #   (FactKeywords::Relatedness `:unknown`), and the two are within STRICT_MAX_DISTANCE;
    # - a .foreign_only? pair (Graphy, #172): one owner's two facts about another project's thing
    #   ("It reads X" / "It doesn't read X") may be a changed dependency, or two passing mentions.
    #
    # @param first [MemoryObservation] with its keyword path computed
    # @param second [MemoryObservation]
    # @param distance [Float] their cosine distance
    # @return [Boolean]
    def fallback?(first, second, distance)
      return false if dated_events?(first.content, second.content)
      return true if foreign_only?(first, second)
      return false if distance.to_f > STRICT_MAX_DISTANCE

      FactKeywords::Relatedness.compare(first, second).subject == :unknown
    end

    # Whether two facts of one owner share a subject only through mentions of another project's
    # things (its root, or entities it owns). The fallback lets the judge decide these, with the guard
    # lowered from "keep" to "context" (FactSupersede::ContradictionFallback).
    #
    # @param first [MemoryObservation] with its keyword path computed
    # @param second [MemoryObservation]
    # @return [Boolean]
    def foreign_only?(first, second)
      return false unless first.memory_entity_id == second.memory_entity_id
      return false unless FactKeywords::Relatedness.compare(first, second).same_subject

      foreign = foreign_mentions(first, second)
      foreign.any? && !FactKeywords::Relatedness.compare(first, second, ignore: foreign).same_subject
    end

    # The re-check behind review policies (1.85.0): whether two live observations would still make a
    # contradiction row under the current rules. Both active, opposite polarity, not two dated
    # events, and (with fact keywords on) .pairable; pending keyword paths are computed first (no
    # LLM call). The vector distance isn't re-checked: an edit makes a new observation.
    #
    #   ContradictionDetector.still_pairable?(row_first, row_second) # => true
    #
    # @param observation_1 [MemoryObservation, Integer] an observation or its id
    # @param observation_2 [MemoryObservation, Integer]
    # @return [Boolean]
    def still_pairable?(observation_1, observation_2)
      ids = [ observation_1, observation_2 ].map { |observation| observation.respond_to?(:id) ? observation.id : observation.to_i }
      pair = MemoryObservation.active.where(id: ids).includes(:memory_entity).index_by(&:id).values_at(*ids)
      return false if ids.uniq.size < 2 || pair.any?(&:nil?)

      first, second = pair
      return false unless polarity_conflict?(first.content, second.content)
      return false if dated_events?(first.content, second.content)
      return true unless keyword_gate?

      FactKeywords.ensure!(pair)
      FactKeywords::Relatedness.computed?(first, second) && pairable(first, second).present?
    end

    # @param first_text [String, nil]
    # @param second_text [String, nil]
    # @return [Boolean] both texts are dated events ("[2026-08-26] …"): two events don't contradict
    def dated_events?(first_text, second_text)
      DATED_EVENT.match?(first_text.to_s) && DATED_EVENT.match?(second_text.to_s)
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

    # The two facts' mentions that belong to another project than their owners': another Project
    # root, or an entity another project owns. A name some entity of the owners' projects (or of no
    # project) holds isn't foreign. Owners without any project leave nothing foreign.
    #
    # @return [Array<String>]
    def foreign_mentions(first, second)
      names = first.keyword_mentions | second.keyword_mentions
      return [] if names.empty?

      projects = [ first, second ].filter_map { |fact| fact.memory_entity && FactKeywords.project_of(fact.memory_entity)&.id }.uniq
      return [] if projects.empty?

      homes = MemoryEntity.where(name: names).pluck(:name, :id, :entity_type, :project_id)
                          .group_by(&:first).transform_values do |rows|
        rows.map { |_name, id, type, project_id| project_id || (id if type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE) }
      end
      names.select do |name|
        list = homes.fetch(name, [])
        list.any? && list.none? { |home| home.nil? || projects.include?(home) }
      end
    end

    # @return [Scan]
    def find_contradiction_pairs(observations, max_distance, max_results)
      pairs = []
      fallback = []
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
          next if dated_events?(anchor.content, candidate.content)

          distance = candidate[:vec_distance].to_f
          comparison = nil
          if gate
            other = by_id[candidate.id]
            next unless other && FactKeywords::Relatedness.computed?(anchor, other)

            comparison = pairable(anchor, other)
            fallback << result(anchor.id, candidate.id, distance) if comparison.nil? && fallback?(anchor, other, distance)
            next unless comparison
          end

          pairs << result(anchor.id, candidate.id, distance, comparison)
        end
      end

      Scan.new(pairs: top(pairs, max_results), fallback: top(fallback, max_results))
    end

    def result(first_id, second_id, distance, comparison = nil)
      Result.new(observation_id_1: first_id, observation_id_2: second_id, distance: distance, confidence: contradiction_confidence(distance),
                 shared_keywords: comparison&.shared, strong: comparison&.strong)
    end

    # De-duplicate symmetric pairs (a,b) and (b,a), best confidence first.
    def top(pairs, max_results)
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
