# frozen_string_literal: true

module FactSupersede
  # Candidates → LegacyGuard → Judge → review rows: the one pipeline behind FactSupersedeJob and
  # detect_contradictions' `outdated_by_fact` mode. It never writes an observation: "keep"
  # candidates are dropped, `still_valid` and `unrelated` verdicts are dropped, and the
  # `superseded` and `unjudged` ones become `fact_supersede` rows ("Outdated by a fact").
  #
  # Pairs that already have a row aren't judged again, except a pending `unjudged` row while the
  # LLM is usable (seeded with the LLM off, or past the tool's cap): a `superseded` verdict
  # refreshes it, `still_valid` / `unrelated` dismisses it without suppression.
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
    # @!attribute known [Integer] candidates skipped before the judge: their pair already has a
    #   pending row or a suppression (a dismissal), so judging them again would change nothing
    # @!attribute judged [Boolean] whether any verdict came from the LLM
    # @!attribute capped [Integer] candidates left unjudged by max_batches (a later uncapped run judges them)
    # @!attribute rejudged [Integer] pending unjudged rows judged now (refreshed or dismissed)
    Result = Data.define(:items, :rows, :searched, :candidates, :kept, :known, :judged, :capped, :rejudged)

    # @param fact [MemoryObservation] an active source fact
    # @param terms [Array<String>] extra search terms (≤ SourceFact::MAX_TERMS in all)
    # @param limit [Integer] most proposals (the review run cap)
    # @param seed [Boolean] seed review rows
    # @param max_batches [Integer, nil] judge at most this many batches (Judge), nil for all
    # @return [Result]
    def self.call(fact, terms: [], limit: ReviewRowClassifier::RUN_CAPS.fetch(KIND), seed: true, max_batches: nil)
      new(fact, terms: terms, limit: limit, seed: seed, max_batches: max_batches).call
    end

    def initialize(fact, terms:, limit:, seed:, max_batches:)
      @fact = fact
      @terms = terms
      @limit = limit
      @seed = seed
      @max_batches = max_batches
    end

    # @see .call
    def call
      found = Candidates.call(@fact, terms: @terms, limit: @limit)
      if !found.vector && found.terms.empty?
        return Result.new(items: [], rows: [], searched: false, candidates: 0, kept: 0, known: 0, judged: false, capped: 0, rejudged: 0)
      end

      guarded = LegacyGuard.new(@fact).apply(found.candidates)
      kept, rest = guarded.partition { |candidate| candidate.guard == LegacyGuard::KEEP }
      known_ids, rejudge_rows = known_pairs(rest)
      to_judge = rest.reject { |candidate| known_ids.include?(candidate.observation.id) }
      verdicts = Judge.call(@fact, to_judge, max_batches: @max_batches)
      rejudged, verdicts = verdicts.partition { |verdict| rejudge_rows.key?(verdict.candidate.observation.id) }
      refreshed = rejudged.count { |verdict| refresh(rejudge_rows.fetch(verdict.candidate.observation.id), verdict) }
      items = verdicts.select { |verdict| PROPOSAL_VERDICTS.include?(verdict.verdict) }.first(@limit).map { |verdict| item(verdict) }
      rows = @seed && items.any? ? CompactionReviewService.seed_report(report_type: REPORT_TYPE, source: SOURCE, source_ref: "fact:#{@fact.id}", items: items) : []
      Result.new(items: items, rows: rows, searched: true, candidates: found.candidates.size, kept: kept.size, known: known_ids.size,
                 judged: (verdicts + rejudged).any?(&:judged), capped: (verdicts + rejudged).count(&:capped), rejudged: refreshed)
    end

    private

    # The candidates whose pair (signature fact:<id>|obs:<id>) already has a pending row or an
    # in-force suppression (seed_report would skip them), except pending `unjudged` rows while the
    # LLM is usable: those are judged again.
    #
    # @return [Array(Set<Integer>, Hash{Integer => MaintenanceReportRow})] the known observation
    #   ids, and the rows to judge again by observation id
    def known_pairs(candidates)
      signatures = candidates.to_h { |candidate| [ "fact:#{@fact.id}|obs:#{candidate.observation.id}", candidate.observation.id ] }
      return [ Set.new, {} ] if signatures.empty?

      pending = MaintenanceReportRow.by_report_type(REPORT_TYPE).pending.where(kind: KIND, signature: signatures.keys).to_a
      # Only a seeding run can refresh a row, so only it spends LLM calls on them.
      rejudge = @seed && SummarizationConfig.llm_usable? ? pending.select { |row| row.payload["verdict"] == Judge::UNJUDGED } : []
      suppressed = MaintenanceReportSuppression.in_force.where(report_type: REPORT_TYPE, signature: signatures.keys).pluck(:signature)
      known = ((pending - rejudge).map(&:signature) + suppressed).to_set { |signature| signatures[signature] }
      [ known, rejudge.index_by { |row| signatures[row.signature] } ]
    end

    # @return [Boolean] whether the row changed (an unjudged verdict leaves it as it is)
    def refresh(row, verdict)
      return false unless verdict.judged

      if verdict.verdict == "superseded"
        payload = item(verdict).merge("detected_at" => row.payload["detected_at"])
        row.update!(payload: payload, **ReviewRowClassifier.call(kind: KIND, payload: payload, created_at: row.created_at).slice(:confidence, :priority))
      else
        row.update!(status: "dismissed", dismissed_at: Time.current, resolved_by: "generator", expires_at: nil,
                    resolution_reason: "the judge found it #{verdict.verdict.tr('_', ' ')}")
      end
      true
    end

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
