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
  # @!attribute subject [Symbol, nil] the keyword paths' answer (FactKeywords::Relatedness: :related,
  #   :unrelated, :one_sided or :unknown), nil with fact keywords off (1.78.0)
  # @!attribute shared_keywords [Array<String>, nil] the names both paths share
  # @!attribute strong [Boolean, nil] the paths share their first mention
  # @!attribute level [String, nil] "same", "related" or "unclear" (1.82.0, Comparison#level), for the judge
  # @!attribute same_fact [Boolean, nil] the fact covers the candidate's subject and states a different
  #   detail (Comparison#same_fact_different_detail?)
  Candidate = Struct.new(:observation, :score, :distance, :term, :polarity_flip, :scoped, :guard, :guard_reason,
                         :subject, :shared_keywords, :strong, :level, :same_fact, keyword_init: true) do
    # @return [Hash] what found it, for the review row and the page
    # The keyword comparison isn't in it: review payloads reach MCP verbatim, and the review view
    # recomputes the shared names from the live paths.
    def signals
      { "distance" => distance&.round(4), "term" => term, "polarity_flip" => polarity_flip, "scoped" => scoped }.compact
    end

    # @return [Boolean] the keyword paths say the two facts are about different things
    #   (FactKeywords::Relatedness: siblings, or mentions with none in common) and no search term
    #   matched: the pair is neither judged nor proposed (1.80.0)
    def unrelated?
      subject == :unrelated && term.nil?
    end

    # @return [Boolean] whether an unjudged row may be proposed (1.82.0): only for the same fact with a
    #   different detail, or a search-term match. Being related isn't enough without the judge. With
    #   fact keywords off (no subject), as before.
    def seed_unjudged?
      term.present? || subject.nil? || same_fact == true
    end
  end
end
