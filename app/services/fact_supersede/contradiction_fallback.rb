# frozen_string_literal: true

module FactSupersede
  # The contradiction detector's `:unknown` fallback pairs (two close facts that mention no entity,
  # opposite polarity), routed through fact supersede's own filters instead of becoming
  # contradiction rows (1.85.0, Steve's decision 2). The real ones were all "the newer procedure
  # replaces the older". Per pair, closest first:
  #
  # - skipped while either side's LLM words are pending (with LLM words on): the words may give the
  #   pair a subject, and the next stale scan retries it once they land;
  # - skipped across projects (a fact never outdates another project) and when the pair already has
  #   a pending fact_supersede row or a dismissal;
  # - LegacyGuard, with the newer observation as the fact: "keep" drops the pair;
  # - Judge (task :judge), newer as the fact, older as the candidate, at most MAX_JUDGE_CALLS calls
  #   per scan (one batch per fact); only a judged `superseded` verdict becomes an item.
  #
  # Nothing at all with fact supersede off (AppSettings.fact_supersede_enabled?). Every pair the judge
  # couldn't take (past the cap, cut from a fact's batch, no usable LLM, no answer) comes back in
  # `leftovers` for the next scan to retry; `outcomes` says what became of the others, for the stale
  # scan to close the old contradiction rows it rerouted here.
  #
  # Items have Proposals.item's shape plus `"origin" => ORIGIN`: the fact need not be a tagged
  # source fact (the apply and the dangling policy read the origin), and the row is never
  # auto-applied (SourceFact#operator_confirmed_fact? is false for it). The caller seeds them.
  #
  #   result = FactSupersede::ContradictionFallback.call(ContradictionDetector.scan(entity.id).fallback)
  #   result.items.first # => { "kind" => "fact_supersede", "verdict" => "superseded", "origin" => "contradiction_fallback", ... }
  class ContradictionFallback
    ORIGIN = "contradiction_fallback"
    # The most judge calls one stale scan spends on fallback pairs.
    MAX_JUDGE_CALLS = 10

    # @!attribute items [Array<Hash>] fact_supersede review items (superseded verdicts only)
    # @!attribute outcomes [Hash{Array(Integer, Integer) => String}] by the pair's sorted ids, what was
    #   decided: "judged: <verdict>", "kept: <why>" (LegacyGuard, or two projects) or "already queued"
    #   (a pending fact_supersede row or a dismissal); deferred and leftover pairs have none
    # @!attribute leftovers [Array<ContradictionDetector::Result>] pairs the judge couldn't take, to retry
    # @!attribute judge_calls [Integer] judge calls made
    # @!attribute deferred [Integer] pairs skipped while LLM words are pending
    # @!attribute kept [Integer] pairs LegacyGuard kept, or across two projects
    # @!attribute known [Integer] pairs with a pending row or a dismissal already
    # @!attribute over_cap [Integer] pairs left unjudged by MAX_JUDGE_CALLS or by a fact's one batch
    Result = Data.define(:items, :outcomes, :leftovers, :judge_calls, :deferred, :kept, :known, :over_cap)

    # @param pair [ContradictionDetector::Result, Array]
    # @return [Array(Integer, Integer)] the pair's observation ids, sorted (the outcomes' key)
    def self.key(pair) = [ pair.observation_id_1, pair.observation_id_2 ].map(&:to_i).sort

    # @param pairs [Array<ContradictionDetector::Result>] the detector's fallback pairs
    # @param max_judge_calls [Integer]
    # @return [Result]
    def self.call(pairs, max_judge_calls: MAX_JUDGE_CALLS)
      new(pairs, max_judge_calls).call
    end

    def initialize(pairs, max_judge_calls)
      @pairs = Array(pairs).uniq { |pair| self.class.key(pair) }.sort_by { |pair| pair.distance.to_f }
      @max_judge_calls = max_judge_calls
      @counts = Hash.new(0)
      @outcomes = {}
      @leftovers = []
    end

    # @see .call
    def call
      return result([]) if @pairs.empty? || !AppSettings.fact_supersede_enabled?

      entries = known_filter(@pairs.filter_map { |pair| entry(pair) })
      return result([]).tap { @leftovers.concat(entries.map(&:last)) } unless Llm::Router.usable?(:judge)

      groups = entries.group_by(&:first).to_a
      groups.drop(@max_judge_calls).each { |_fact, rest| leave(rest.map(&:last)) }
      verdicts = groups.first(@max_judge_calls).flat_map { |fact, group| judge(fact, group) }
      result(verdicts.select { |_fact, verdict| verdict.verdict == "superseded" }
                     .map { |fact, verdict| Proposals.item(fact, verdict).merge("origin" => ORIGIN) })
    end

    private

    # @return [Array<Array(MemoryObservation, Judge::Verdict)>] the judged verdicts (the rest are left over)
    def judge(fact, group)
      @counts[:judge_calls] += 1
      pairs = group.to_h { |_fact, candidate, pair| [ candidate.observation.id, pair ] }
      Judge.call(fact, group.map { |entry| entry[1] }, max_batches: 1).filter_map do |verdict|
        pair = pairs.fetch(verdict.candidate.observation.id)
        next leave([ pair ]) unless verdict.judged

        @outcomes[self.class.key(pair)] = "judged: #{verdict.verdict}"
        [ fact, verdict ]
      end
    end

    def leave(pairs)
      @counts[:over_cap] += pairs.size
      @leftovers.concat(pairs)
      nil
    end

    def result(items)
      Result.new(items: items, outcomes: @outcomes, leftovers: @leftovers, judge_calls: @counts[:judge_calls], deferred: @counts[:deferred],
                 kept: @counts[:kept], known: @counts[:known], over_cap: @counts[:over_cap])
    end

    # @return [Array(MemoryObservation, Candidate, ContradictionDetector::Result), nil] the newer
    #   observation, the older as a guarded candidate, and the pair; nil when the pair is skipped
    def entry(pair)
      fact_and_candidate(pair)&.push(pair)
    end

    # @return [Array(MemoryObservation, Candidate), nil] the newer observation and the older as a
    #   guarded candidate; nil when the pair is skipped (counted)
    def fact_and_candidate(pair)
      fact, older = observations.values_at(pair.observation_id_1.to_i, pair.observation_id_2.to_i)
      return nil unless fact && older

      fact, older = older, fact if ([ older.created_at, older.id ] <=> [ fact.created_at, fact.id ]).positive?
      return count(:deferred) if words_pending?(fact, older)
      return decide(pair, :kept, "kept: two projects") unless fact.fact_project_id == older.fact_project_id

      candidate = candidate(older, pair.distance)
      candidate.guard, candidate.guard_reason = LegacyGuard.new(fact).check(older)
      candidate.guard == LegacyGuard::KEEP ? decide(pair, :kept, "kept: #{candidate.guard_reason}") : [ fact, candidate ]
    end

    def decide(pair, counter, outcome)
      @outcomes[self.class.key(pair)] = outcome
      count(counter)
    end

    def candidate(observation, distance)
      score = [ 1.0 - distance.to_f + Candidates::POLARITY_BOOST, Candidates::MAX_SCORE ].min.round(3)
      Candidate.new(observation: observation, score: score, distance: distance.to_f, term: nil, polarity_flip: true, scoped: true,
                    subject: :unknown, shared_keywords: [], strong: false, level: "unclear", same_fact: false)
    end

    def words_pending?(*facts)
      FactKeywords::LlmWords.enabled? && facts.any? { |fact| fact.llm_keywords_at.nil? }
    end

    # Drops the pairs whose signature already has a pending row or an in-force suppression.
    def known_filter(entries)
      signatures = entries.map { |fact, candidate, _pair| "fact:#{fact.id}|obs:#{candidate.observation.id}" }
      return entries if signatures.empty?

      known = MaintenanceReportRow.by_report_type(Proposals::REPORT_TYPE).pending.where(kind: Proposals::KIND, signature: signatures).pluck(:signature)
      known += MaintenanceReportSuppression.in_force.where(report_type: Proposals::REPORT_TYPE, signature: signatures).pluck(:signature)
      known = known.to_set
      entries.zip(signatures).filter_map { |entry, signature| known.include?(signature) ? decide(entry.last, :known, "already queued") : entry }
    end

    def count(key)
      @counts[key] += 1
      nil
    end

    def observations
      @observations ||= MemoryObservation.active.includes(:memory_entity)
                                         .where(id: @pairs.flat_map { |pair| [ pair.observation_id_1, pair.observation_id_2 ] }.map(&:to_i))
                                         .index_by(&:id)
    end
  end
end
