# frozen_string_literal: true

# Proposes what a new or changed source fact outdates (fact supersede F4): FactSupersede::Proposals
# seeds "Outdated by a fact" review rows, then the review policies run (auto-apply is off by
# default). Queued by MemoryObservation's after_commit (SourceFact). One job per fact at a time
# (Solid Queue's concurrency control, keyed by the fact id); a stale or unmarked fact is a no-op.
class FactSupersedeJob < ApplicationJob
  queue_as :low_priority
  limits_concurrency to: 1, key: ->(fact_id) { "fact:#{fact_id}" }

  # @param fact_id [Integer]
  # @return [FactSupersede::Proposals::Result, nil] nil when the fact is gone, no longer a fact, or the feature is off
  def perform(fact_id)
    fact = MemoryObservation.includes(:memory_entity).find_by(id: fact_id)
    return unless fact&.source_fact? && AppSettings.fact_supersede_enabled?

    progress = OperationProgress.start!(operation_type: "fact_supersede", total_count: 1, phase: "searching",
                                        message: "Looking for what source fact ##{fact.id} outdates", details: { fact_observation_id: fact.id })
    result = FactSupersede::Proposals.call(fact)
    progress.complete!(message: summary(result), counters: { candidates: result.candidates, kept: result.kept, proposed: result.rows.size,
                                                                       rejudged: result.rejudged })
    ReviewPolicyJob.enqueue_if_seeded(trigger: "fact_supersede", seeded: result.rows)
    result
  rescue StandardError => e
    progress&.fail!(e)
    raise
  end

  private

  def summary(result)
    return "Nothing to search: similarity search is off and the fact has no replaces: terms" unless result.searched

    "#{result.rows.size} new proposal(s) from #{result.candidates} candidate(s)#{'; LLM unavailable, all unjudged' unless result.judged || result.items.empty?}"
  end
end
