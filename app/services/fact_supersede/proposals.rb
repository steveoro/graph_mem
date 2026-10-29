# frozen_string_literal: true

module FactSupersede
  # Candidates → LegacyGuard → Judge → review rows: the one pipeline behind FactSupersedeJob and
  # detect_contradictions' `outdated_by_fact` mode. It never writes an observation: "keep"
  # candidates are dropped, `still_valid` and `unrelated` verdicts are dropped, and the
  # `superseded` and `unjudged` ones become `fact_supersede` rows ("Outdated by a fact").
  #
  #   result = FactSupersede::Proposals.call(fact)
  #   result.items.first # => { "kind" => "fact_supersede", "fact_observation_id" => 12, "observation_id" => 15, "verdict" => "superseded", ... }
  #   result.rows        # => the MaintenanceReportRows seeded (none already pending or dismissed)
  class Proposals
    REPORT_TYPE = "compaction_review"
    SOURCE = "fact_supersede"
    KIND = "fact_supersede"
    PROPOSAL_VERDICTS = [ "superseded", Judge::UNJUDGED ].freeze
    # How much of each text a row carries (apply re-reads the live rows).
    CONTENT_LIMIT = 300

    # @!attribute items [Array<Hash>] the proposals (review item payloads)
    # @!attribute rows [Array<MaintenanceReportRow>] seeded rows (empty when seed is false or all were known)
    # @!attribute searched [Boolean] false when there was nothing to search (no vectors and no terms)
    # @!attribute candidates [Integer] candidates found
    # @!attribute kept [Integer] candidates the guard kept ("keep")
    # @!attribute judged [Boolean] whether any verdict came from the LLM
    Result = Data.define(:items, :rows, :searched, :candidates, :kept, :judged)

    # @param fact [MemoryObservation] an active source fact
    # @param terms [Array<String>] extra search terms (≤ SourceFact::MAX_TERMS in all)
    # @param limit [Integer] most proposals (the review run cap)
    # @param seed [Boolean] seed review rows
    # @return [Result]
    def self.call(fact, terms: [], limit: ReviewRowClassifier::RUN_CAPS.fetch(KIND), seed: true)
      new(fact, terms: terms, limit: limit, seed: seed).call
    end

    def initialize(fact, terms:, limit:, seed:)
      @fact = fact
      @terms = terms
      @limit = limit
      @seed = seed
    end

    # @see .call
    def call
      found = Candidates.call(@fact, terms: @terms, limit: @limit)
      return Result.new(items: [], rows: [], searched: false, candidates: 0, kept: 0, judged: false) if !found.vector && found.terms.empty?

      guarded = LegacyGuard.new(@fact).apply(found.candidates)
      kept, judged_candidates = guarded.partition { |candidate| candidate.guard == LegacyGuard::KEEP }
      verdicts = Judge.call(@fact, judged_candidates)
      items = verdicts.select { |verdict| PROPOSAL_VERDICTS.include?(verdict.verdict) }.first(@limit).map { |verdict| item(verdict) }
      rows = @seed && items.any? ? CompactionReviewService.seed_report(report_type: REPORT_TYPE, source: SOURCE, source_ref: "fact:#{@fact.id}", items: items) : []
      Result.new(items: items, rows: rows, searched: true, candidates: found.candidates.size, kept: kept.size, judged: verdicts.any?(&:judged))
    end

    private

    def item(verdict)
      candidate = verdict.candidate
      observation = candidate.observation
      entity = observation.memory_entity
      {
        "kind" => KIND, "fact_observation_id" => @fact.id, "observation_id" => observation.id,
        "fact_content" => @fact.content.to_s.truncate(CONTENT_LIMIT), "fact_entity_name" => @fact.memory_entity.name,
        "content" => observation.content.to_s.truncate(CONTENT_LIMIT), "entity_id" => entity.id, "entity_name" => entity.name,
        "project_id" => candidate.scoped ? @fact.fact_project_id : nil,
        "project_name" => candidate.scoped ? MemoryEntity.where(id: @fact.fact_project_id).pick(:name) : nil,
        "verdict" => verdict.verdict, "confidence" => verdict.confidence, "reason" => verdict.reason, "replacement" => verdict.replacement,
        "guard" => candidate.guard, "guard_reason" => candidate.guard_reason, "signals" => candidate.signals,
        "detected_at" => Time.current.iso8601
      }
    end
  end
end
