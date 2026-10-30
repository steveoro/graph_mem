# frozen_string_literal: true

# Fact supersede (1.64.0): a source fact (an observation tagged `source-fact`, see SourceFact)
# outdates the observations of the same project it contradicts. Never by age, never across
# projects. The pieces:
#
# - Candidates: the fact's project's observations that may contradict it (vector and term match);
# - LegacyGuard: keeps statements about another project, a version, an environment or a work log;
# - Judge: asks the local LLM, per candidate, superseded / still_valid / unrelated.
module FactSupersede
  # One observation that may be outdated by the fact.
  #
  # @!attribute observation [MemoryObservation]
  # @!attribute score [Float] 0-0.99: max(1 - distance, term hit ? 0.6 : 0) + 0.1 on a polarity flip
  # @!attribute distance [Float, nil] cosine distance to the fact (nil: not found by vector)
  # @!attribute term [String, nil] the first search term the text contains
  # @!attribute polarity_flip [Boolean] exactly one of the two texts is negative
  # @!attribute scoped [Boolean] false for an entity without a project related to the fact's entity
  # @!attribute guard [String, nil] "keep" (never proposed), "context" (never auto-applied) or nil
  # @!attribute guard_reason [String, nil]
  Candidate = Struct.new(:observation, :score, :distance, :term, :polarity_flip, :scoped, :guard, :guard_reason,
                         keyword_init: true) do
    # @return [Hash] what found it, for the review row and the page
    def signals
      { "distance" => distance&.round(4), "term" => term, "polarity_flip" => polarity_flip, "scoped" => scoped }.compact
    end
  end
end
